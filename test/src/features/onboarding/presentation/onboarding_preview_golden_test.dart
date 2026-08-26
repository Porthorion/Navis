import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_screen.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpOnboarding(
    WidgetTester tester,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.binding.setSurfaceSize(size);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      return tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          customColorPresetsProvider.overrideWithValue(
            const AsyncData(<int>[]),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            CloneDiagnosticsExternalScrobbleCredentialStore(),
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
  }

  Future<void> captureSteps(
    WidgetTester tester,
    String prefix,
  ) async {
    for (var step = 1; step <= 4; step++) {
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/${prefix}_step$step.png'),
      );
      if (step < 4) {
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
      }
    }
  }

  testWidgets('captures desktop onboarding steps', (tester) async {
    await pumpOnboarding(tester, const Size(1280, 800));
    await captureSteps(tester, 'onboarding_desktop');
  });

  testWidgets('captures mobile onboarding steps', (tester) async {
    await pumpOnboarding(tester, const Size(390, 844));
    await captureSteps(tester, 'onboarding_mobile');
  });
}
