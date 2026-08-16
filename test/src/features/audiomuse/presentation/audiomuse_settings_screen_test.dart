import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/audiomuse/presentation/audiomuse_settings_screen.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_theme.dart';

class _MockSettingsRepository extends Mock implements SettingsRepository {}

void main() {
  late _MockSettingsRepository repository;

  setUpAll(() {
    registerFallbackValue(const AppSettingsModel.defaults());
  });

  setUp(() {
    repository = _MockSettingsRepository();
    when(() => repository.saveSettings(any())).thenAnswer((_) async {});
  });

  testWidgets('renders the AudioMuse configuration entry point on desktop', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1280, 800));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
        ],
        child: _app(desktopMode: true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('AudioMuse AI'), findsOneWidget);
    expect(find.text('Enable AudioMuse'), findsOneWidget);
    expect(find.byTooltip('Back to Settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps settings-load failures actionable and safe', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(
            AsyncError<AppSettingsModel>(
              StateError('Connection refused'),
              StackTrace.empty,
            ),
          ),
        ],
        child: _app(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not load AudioMuse settings'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('Connection refused'), findsNothing);
  });

  testWidgets('keeps the enabled form usable at 200% text scale', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(360, 800));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
        ],
        child: _app(textScaler: const TextScaler.linear(2)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNWidgets(2));
    await tester.scrollUntilVisible(
      find.text('Test connection'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Test connection'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _app({bool desktopMode = false, TextScaler? textScaler}) {
  return MaterialApp(
    theme: testTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: textScaler == null
        ? null
        : (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child!,
          ),
    home: desktopMode
        ? AdaptiveContextScope(
            adaptiveContext: resolveAdaptiveContext(
              desktopRuntime: true,
              viewportSize: const Size(1280, 800),
              safePadding: EdgeInsets.zero,
            ),
            child: const AudioMuseSettingsScreen(),
          )
        : const AudioMuseSettingsScreen(),
  );
}
