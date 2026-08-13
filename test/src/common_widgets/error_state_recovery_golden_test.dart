import 'package:flutter/material.dart';
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
}
