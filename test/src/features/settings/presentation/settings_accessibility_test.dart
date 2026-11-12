import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/features/onboarding/presentation/setup_highlights_provider.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/presentation/interface_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/themes_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/sync_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/playback_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/privacy_screen.dart';
import 'package:navis/src/features/settings/presentation/settings_screen.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_database.dart';

List<Override> _overrides(NavisDatabase database) => withTestDatabase(
  database,
  overrides: [
    pendingSetupHighlightsProvider.overrideWithValue(const <SetupHighlight>{}),
    appSettingsProvider.overrideWithValue(
      const AsyncData(AppSettingsModel.defaults()),
    ),
  ],
);

void main() {
  // One database for the file: a provider-created one per test is closed
  // asynchronously, so the next test's would overlap it and drift would warn.
  final database = createTestDatabase();
  tearDownAll(database.close);
  final screens = <String, Widget>{
    'Settings': const SettingsScreen(),
    'Playback settings': const PlaybackSettingsScreen(),
    'Themes': const ThemesSettingsScreen(),
    'Interface': const InterfaceSettingsScreen(),
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
            overrides: _overrides(database),
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
}
