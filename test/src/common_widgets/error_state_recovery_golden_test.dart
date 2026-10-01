import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/error_state.dart';

import '../../helpers/test_theme.dart';

void main() {
  Future<void> pumpState(
    WidgetTester tester, {
    required bool showTechnicalMessage,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ErrorState(
            title: 'Could not load albums',
            message: showTechnicalMessage
                ? 'SocketException: Failed host lookup: music.example.test'
                : null,
            onRetry: () {},
          ),
        ),
      ),
    );
  }

  testWidgets('error state before exposes a technical failure', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpState(tester, showTechnicalMessage: true);

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/error_state_before.png'),
    );
  });

  testWidgets('error state gives a clear recovery hint instead', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpState(tester, showTechnicalMessage: false);

    expect(find.text('Check your connection and try again.'), findsOneWidget);
    expect(find.textContaining('SocketException'), findsNothing);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/error_state_after.png'),
    );
  });

  testWidgets('long recovery copy remains reachable at large text scale', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 280));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: ErrorState(
              title: 'Could not load the current playlist details',
              message: 'Check your connection, then try again. Your saved music remains available on this device.',
              onRetry: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
