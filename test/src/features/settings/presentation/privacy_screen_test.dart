import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/settings/presentation/privacy_screen.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_theme.dart';

void main() {
  Future<void> pumpPrivacy(
    WidgetTester tester, {
    required AdaptiveContext adaptiveContext,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AdaptiveContextScope(
          adaptiveContext: adaptiveContext,
          child: const PrivacyScreen(),
        ),
      ),
    );
  }

  testWidgets('desktop privacy uses the responsive two-column layout', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1280, 800));
    await pumpPrivacy(
      tester,
      adaptiveContext: resolveAdaptiveContext(
        desktopRuntime: true,
        viewportSize: const Size(1280, 800),
        safePadding: EdgeInsets.zero,
      ),
    );
    await tester.pumpAndSettle();

    final accounts = find.text('Accounts and Credentials');
    final scrobbling = find.text('External Scrobbling');
    expect(tester.getTopLeft(accounts).dy, tester.getTopLeft(scrobbling).dy);
    expect(
      tester.getTopLeft(accounts).dx,
      lessThan(tester.getTopLeft(scrobbling).dx),
    );
    await expectLater(
      find.byType(PrivacyScreen),
      matchesGoldenFile('goldens/privacy_screen_desktop.png'),
    );
  });

  testWidgets('phone privacy keeps a single reading column', (tester) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    await pumpPrivacy(
      tester,
      adaptiveContext: resolveAdaptiveContext(
        desktopRuntime: false,
        viewportSize: const Size(390, 844),
        safePadding: EdgeInsets.zero,
      ),
    );
    await tester.pumpAndSettle();

    final accounts = find.text('Accounts and credentials');
    final scrobbling = find.text('External scrobbling');
    expect(tester.getTopLeft(accounts).dx, tester.getTopLeft(scrobbling).dx);
    expect(
      tester.getTopLeft(accounts).dy,
      lessThan(tester.getTopLeft(scrobbling).dy),
    );
  });
}
