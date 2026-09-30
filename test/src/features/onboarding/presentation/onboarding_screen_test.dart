import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_screen.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

void main() {
  testWidgets('renders a shell-free full-screen customization flow', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          customColorPresetsProvider.overrideWithValue(
            const AsyncData(<int>[]),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: OnboardingScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Make Navis Yours'), findsOneWidget);
    expect(find.text('Step 1 of 4'), findsOneWidget);
    expect(find.text('Choose Your Look'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
  });

  testWidgets('shows the dependent liked queue choice', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          customColorPresetsProvider.overrideWithValue(
            const AsyncData(<int>[]),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: OnboardingScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Queue All Liked Songs'), findsOneWidget);
    expect(find.text('Download Only on Wi-Fi'), findsOneWidget);
  });

  testWidgets('previews appearance changes and exposes detailed crossfade', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          customColorPresetsProvider.overrideWithValue(
            const AsyncData(<int>[]),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: OnboardingScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final initialPrimary = Theme.of(
      tester.element(find.byType(Scaffold)),
    ).colorScheme.primary;
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.light,
    );
    await tester.tap(find.bySemanticsLabel('Deep Orange'));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).colorScheme.primary,
      isNot(initialPrimary),
    );

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Crossfade'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Crossfade'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('Crossfade duration:'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Crossfade duration:'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Crossfade type'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Crossfade type'), findsOneWidget);
  });

  testWidgets('presents an established ListenBrainz connection as status', (
    tester,
  ) async {
    final settings = const AppSettingsModel.defaults().copyWith(
      listenBrainzTokenValid: true,
      listenBrainzScrobblingEnabled: true,
      listenBrainzUserName: 'navis-user',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(AsyncData(settings)),
          customColorPresetsProvider.overrideWithValue(
            const AsyncData(<int>[]),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: OnboardingScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (var step = 0; step < 3; step++) {
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
    }

    await tester.scrollUntilVisible(
      find.text('ListenBrainz connected'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('ListenBrainz connected'), findsOneWidget);
    expect(find.text('Connected as navis-user.'), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);
  });
}
