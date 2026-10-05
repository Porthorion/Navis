import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_screen.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

class _OfflineListenBrainz extends ListenBrainzApiClient {
  @override
  Future<ListenBrainzTokenDetails> validateTokenDetails(
    String userToken, {
    bool userInitiated = false,
  }) {
    throw DioException(
      requestOptions: RequestOptions(path: '/1/validate-token'),
      type: DioExceptionType.connectionError,
    );
  }
}

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
          localizationsDelegates: navisLocalizationsDelegates,
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
          localizationsDelegates: navisLocalizationsDelegates,
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
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: OnboardingScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final initialPrimary = Theme.of(tester.element(find.byType(Scaffold)))
        .colorScheme
        .primary;
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
          localizationsDelegates: navisLocalizationsDelegates,
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

  testWidgets('a network failure while validating shows a readable message', (
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
          listenBrainzApiClientProvider.overrideWithValue(
            _OfflineListenBrainz(),
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
    final token = find.byKey(
      const ValueKey<String>('onboarding-listenbrainz-token'),
    );
    await tester.scrollUntilVisible(
      token,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(token, 'token');
    final validate = find.widgetWithText(FilledButton, 'Validate and connect');
    await tester.scrollUntilVisible(
      validate,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(validate);
    await tester.pumpAndSettle();

    // Shown on the field itself.
    expect(
      tester.widget<TextField>(token).decoration!.errorText,
      'ListenBrainz is unavailable. Check your connection and try again.',
    );
    expect(find.textContaining('DioException'), findsNothing);
  });
}
