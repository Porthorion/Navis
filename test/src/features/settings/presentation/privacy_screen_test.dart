import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/features/settings/presentation/privacy_screen.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/fake_url_launcher.dart';
import '../../../../helpers/test_theme.dart';

void main() {
  Future<void> pumpPrivacy(
    WidgetTester tester, {
    required AdaptiveContext adaptiveContext,
  }) {
    return tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AdaptiveContextScope(
            adaptiveContext: adaptiveContext,
            child: const PrivacyScreen(),
          ),
        ),
      ),
    );
  }

  testWidgets('links to the full privacy policy', (tester) async {
    final launcher = FakeUrlLauncher.install();
    setAdaptiveTestViewport(tester, const Size(412, 900));
    await pumpPrivacy(
      tester,
      adaptiveContext: resolveAdaptiveContext(
        desktopRuntime: false,
        viewportSize: const Size(412, 900),
        safePadding: EdgeInsets.zero,
      ),
    );
    await tester.pumpAndSettle();

    final link = find.byKey(const ValueKey<String>('privacy-full-policy'));
    await tester.scrollUntilVisible(link, 200);
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(find.text('Read the Full Privacy Policy'), findsOneWidget);
    await tester.tap(link);
    await tester.pumpAndSettle();

    expect(launcher.launched, <String>[
      'https://navis.porthorion.com/privacy/app',
    ]);
  });

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
    final onlineServices = find.text('Online Services');
    expect(
      tester.getTopLeft(accounts).dy,
      tester.getTopLeft(onlineServices).dy,
    );
    expect(
      tester.getTopLeft(accounts).dx,
      lessThan(tester.getTopLeft(onlineServices).dx),
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

    final accounts = find.text('Accounts and Credentials');
    final onlineServices = find.text('Online Services');
    expect(
      tester.getTopLeft(accounts).dx,
      tester.getTopLeft(onlineServices).dx,
    );
    expect(
      tester.getTopLeft(accounts).dy,
      lessThan(tester.getTopLeft(onlineServices).dy),
    );
  });

  testWidgets('lists the online services and links to Integrations', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(390, 1400));
    await pumpPrivacy(
      tester,
      adaptiveContext: resolveAdaptiveContext(
        desktopRuntime: false,
        viewportSize: const Size(390, 1400),
        safePadding: EdgeInsets.zero,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Online Services'), findsOneWidget);
    for (final name in <String>[
      'Deezer',
      'Last.fm',
      'ListenBrainz',
      'LRCLIB',
      'downloads.porthorion.com',
      'GitHub',
      'raw.githubusercontent.com',
      'api.github.com',
      "Deezer's image servers",
      'API key included with Navis or your own',
      'Settings › Integrations',
    ]) {
      expect(find.textContaining(name), findsWidgets, reason: name);
    }
    expect(find.text('Open Integrations'), findsOneWidget);
    // Only the ListenBrainz token lives in the secure store.
    expect(find.textContaining('external service tokens'), findsNothing);
  });
}
