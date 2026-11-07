import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/features/onboarding/presentation/setup_highlights_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/presentation/appearance_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/sync_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/playback_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/privacy_screen.dart';
import 'package:navis/src/features/settings/presentation/settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/adaptive_test_harness.dart';

final _overrides = [
  pendingSetupHighlightsProvider.overrideWithValue(const <SetupHighlight>{}),
  appSettingsProvider.overrideWithValue(
    const AsyncData(AppSettingsModel.defaults()),
  ),
];

void main() {
  final screens = <String, Widget>{
    'Settings': const SettingsScreen(),
    'Playback settings': const PlaybackSettingsScreen(),
    'Appearance': const AppearanceSettingsScreen(),
    'Sync': const SyncSettingsScreen(),
    'Privacy': const PrivacyScreen(),
  };
  for (final entry in screens.entries) {
    for (final scale in [2.0, 3.1]) {
      testWidgets('${entry.key} at ${scale}x text is usable', (tester) async {
        final handle = tester.ensureSemantics();
        setAdaptiveTestViewport(tester, const Size(390, 844));
        await tester.pumpWidget(
          ProviderScope(
            overrides: _overrides,
            child: MaterialApp(
              theme: ThemeData(platform: TargetPlatform.iOS),
              localizationsDelegates: navisLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: entry.value,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        // Unmount so the screen's database-backed providers can flush timers.
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        handle.dispose();
      });
    }
  }

  for (final reduce in [true, false]) {
    testWidgets('Appearance blinking icon respects Reduce Motion=$reduce', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(390, 4000));
      await tester.pumpWidget(
        ProviderScope(
          overrides: _overrides,
          child: MaterialApp(
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
              child: child!,
            ),
            home: const AppearanceSettingsScreen(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      // The endless blink stops under Reduce Motion.
      final blink = tester.widget<AnimatedBuilder>(
        find
            .ancestor(
              of: find.byIcon(Icons.remove_red_eye_outlined),
              matching: find.byType(AnimatedBuilder),
            )
            .first,
      );
      expect((blink.animation as AnimationController).isAnimating, !reduce);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });
  }
}
