import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/settings/presentation/settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

void main() {
  testWidgets(
    'desktop UI toggle is visible in settings when desktop v1 is disabled',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            desktopUiV1EnabledProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      if (isDesktopRuntime) {
        expect(find.text('Desktop UI V1'), findsOneWidget);
      } else {
        expect(find.text('Desktop UI V1'), findsNothing);
      }
    },
  );

  testWidgets('tablet settings uses grouped cards in non-desktop mode', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopUiV1EnabledProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    if (!isDesktopRuntime) {
      expect(find.text('Connection'), findsOneWidget);
      expect(find.text('Storage'), findsOneWidget);
      expect(find.text('Playback'), findsOneWidget);
    }
  });
}
