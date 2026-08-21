import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/features/settings/presentation/settings_screen.dart';

import '../../../../helpers/adaptive_test_harness.dart';

void main() {
  testWidgets('removed desktop UI toggle is not shown', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Desktop UI V1'), findsNothing);
  });

  testWidgets('settings layout follows adaptive width parity matrix', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(599, 1000));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(DesktopFrame), findsNothing);
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Settings'), findsNothing);
    expect(tester.takeException(), isNull);

    final transitions = <({Size size, bool desktopWorkspace})>[
      (size: const Size(700, 1000), desktopWorkspace: false),
      (size: const Size(840, 1000), desktopWorkspace: false),
      (size: const Size(1200, 1000), desktopWorkspace: true),
      (size: const Size(900, 420), desktopWorkspace: false),
    ];

    for (final step in transitions) {
      tester.view.physicalSize = step.size;
      await tester.pumpAndSettle();
      expect(
        find.byType(DesktopFrame),
        findsNothing,
      );
      expect(
        find.byType(AppBar),
        step.desktopWorkspace || step.size == const Size(599, 1000)
            ? findsNothing
            : findsOneWidget,
      );
      expect(find.text('Listen Together Configuration'), findsNothing);
      if (step.size.width >= 1200) {
        expect(find.text('Desktop Window'), findsOneWidget);
        expect(
          find.text('Desktop workspace controls and app preferences'),
          findsNothing,
        );
        expect(find.text('Keyboard Shortcuts'), findsOneWidget);
        expect(find.text('Connection'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'does not show separate Listen Together or External Services entries',
    (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Listen Together Configuration'), findsNothing);
      expect(find.text('Listen Together'), findsNothing);
      expect(find.text('External Services'), findsNothing);
      expect(find.text('Configuration'), findsOneWidget);
      expect(find.text('AudioMuse AI'), findsNothing);
    },
  );
}
