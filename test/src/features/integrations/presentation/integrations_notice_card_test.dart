import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/integrations/presentation/integrations_notice_card.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';

import '../../../../helpers/test_database.dart';
import '../../../../helpers/test_theme.dart';

void main() {
  late NavisDatabase database;

  setUp(() => database = createTestDatabase());
  tearDown(() => database.close());

  Future<void> pump(
    WidgetTester tester, {
    bool dismissed = false,
    bool? onboardingRequired = false,
  }) async {
    await tester.runAsync(database.appSettingsDao.getSettings);
    final router = GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: AppRoutes.home,
          builder: (context, state) => const Scaffold(
            body: Column(children: [IntegrationsNoticeCard()]),
          ),
        ),
        GoRoute(
          path: SettingsPage.integrations.location,
          builder: (context, state) =>
              const Scaffold(body: Text('Integrations page')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          database,
          overrides: [
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  integrationsNoticeDismissed: dismissed,
                ),
              ),
            ),
            onboardingRequiredProvider.overrideWithValue(onboardingRequired),
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
    await tester.pumpAndSettle();
  }

  Future<bool> storedDismissed(WidgetTester tester) async {
    final settings = await tester.runAsync(database.appSettingsDao.getSettings);
    return settings!.integrationsNoticeDismissed;
  }

  final open = find.byKey(const ValueKey<String>('integrationsNoticeOpen'));

  testWidgets('says what is new in 1.5.0 after setup', (tester) async {
    await pump(tester);
    expect(open, findsOneWidget);
    expect(find.text('New in 1.5.0'), findsOneWidget);
    expect(
      find.text(
        'Navis can now use Deezer for top songs, artist photos and new '
        'releases. Review integrations.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('stays hidden during setup, while it loads, and once seen', (
    tester,
  ) async {
    await pump(tester, onboardingRequired: true);
    expect(open, findsNothing);
    await pump(tester, onboardingRequired: null);
    expect(open, findsNothing);
    await pump(tester, dismissed: true);
    expect(open, findsNothing);
  });

  testWidgets('closing it records it as seen', (tester) async {
    await pump(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('integrationsNoticeDismiss')),
    );
    await tester.pump();
    expect(open, findsNothing);
    expect(await storedDismissed(tester), isTrue);
  });

  testWidgets('opening it shows Integrations and records it as seen', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(find.text('Integrations page'), findsOneWidget);
    expect(await storedDismissed(tester), isTrue);
  });
}
