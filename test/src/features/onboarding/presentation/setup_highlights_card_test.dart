import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/features/onboarding/presentation/setup_highlights_card.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

void main() {
  late NavisDatabase database;

  setUp(() => database = createTestDatabase());
  tearDown(() => database.close());

  final open = find.byKey(const ValueKey<String>('setupHighlightsOpen'));
  final dismiss = find.byKey(const ValueKey<String>('setupHighlightsDismiss'));

  Future<void> pump(
    WidgetTester tester, {
    int onboardingVersion = currentOnboardingVersion,
    String? seenRelease,
    String? dismissedRelease,
  }) async {
    await tester.runAsync(() async {
      await database.appSettingsDao.getSettings();
      await database.appSettingsDao.completeOnboarding(onboardingVersion);
      if (seenRelease != null) {
        await database.appSettingsDao.updateSetupHighlightsSeenRelease(
          seenRelease,
        );
      }
      if (dismissedRelease != null) {
        await database.appSettingsDao.updateSetupCardDismissedRelease(
          dismissedRelease,
        );
      }
    });
    final router = GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: AppRoutes.home,
          builder: (context, state) =>
              const Scaffold(body: Column(children: [SetupHighlightsCard()])),
        ),
        GoRoute(
          path: AppRoutes.onboarding,
          builder: (context, state) =>
              const Scaffold(body: Text('Onboarding review stub')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            packageInfoProvider.overrideWith(
              (ref) async => PackageInfo(
                appName: 'Navis',
                packageName: 'test.navis',
                version: '1.4.3',
                buildNumber: '10403',
              ),
            ),
          ],
        ),
        child: MaterialApp.router(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  Future<dynamic> row(WidgetTester tester) =>
      tester.runAsync(database.appSettingsDao.getSettings);

  testWidgets('invites an updated user to try the new options', (tester) async {
    await pump(tester);

    expect(open, findsOneWidget);
    expect(find.text('New appearance options'), findsOneWidget);
    expect(find.text('New in 1.4.3'), findsNothing);
    expect(
      find.text(
        'Color styles, corner style, Now Playing background and more. Try '
        'them in Quick Customization.',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Dismiss'), findsOneWidget);
  });

  testWidgets('opens the setup review without acknowledging anything', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(open);
    await tester.pumpAndSettle();

    expect(find.text('Onboarding review stub'), findsOneWidget);
    final stored = await row(tester);
    expect(stored.setupHighlightsSeenRelease, isNull);
    expect(stored.setupCardDismissedRelease, isNull);
  });

  testWidgets('closing hides it at once and records the dismissal', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(dismiss);
    await tester.pump();
    expect(open, findsNothing);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    final stored = await row(tester);
    expect(stored.setupCardDismissedRelease, '1.4.3');
    expect(stored.setupHighlightsSeenRelease, isNull);
  });

  testWidgets('stays hidden before setup, after Finish and once dismissed', (
    tester,
  ) async {
    await pump(tester, onboardingVersion: 0);
    expect(open, findsNothing);
  });

  testWidgets('is hidden once the release is acknowledged', (tester) async {
    await pump(tester, seenRelease: '1.4.3');
    expect(open, findsNothing);
  });

  testWidgets('is hidden when the card was dismissed earlier', (tester) async {
    await pump(tester, dismissedRelease: '1.4.3');
    expect(open, findsNothing);
  });
}
