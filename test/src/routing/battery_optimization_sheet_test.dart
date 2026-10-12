import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/routing/app_shell.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  for (final action in ['Later', 'barrier', 'back', 'Open Settings']) {
    testWidgets('battery sheet snoozes dismissal: $action', (tester) async {
      late BuildContext opener;
      var snoozes = 0;
      var settingsOpened = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(const Color(0xFFE2581E)),
          localizationsDelegates: navisLocalizationsDelegates,
          home: Builder(
            builder: (context) {
              opener = context;
              return const Scaffold();
            },
          ),
        ),
      );
      final dismissed = showBatteryOptimizationSheet(
        opener,
        onOpenSettings: () async => settingsOpened++,
        onSnooze: () async => snoozes++,
      );
      await tester.pumpAndSettle();
      switch (action) {
        case 'barrier':
          await tester.tapAt(const Offset(5, 5));
        case 'back':
          await tester.binding.handlePopRoute();
        default:
          await tester.tap(find.text(action));
      }
      await tester.pumpAndSettle();
      await dismissed;
      expect(snoozes, action == 'Open Settings' ? 0 : 1);
      expect(settingsOpened, action == 'Open Settings' ? 1 : 0);
    });
  }

  testWidgets('battery sheet follows a live theme switch', (tester) async {
    const seed = Color(0xFFE2581E);
    final mode = ValueNotifier<ThemeMode>(ThemeMode.dark);
    addTearDown(mode.dispose);
    final light = buildLightTheme(seed);
    final dark = buildDarkTheme(seed);
    late BuildContext opener;

    await tester.pumpWidget(
      ValueListenableBuilder<ThemeMode>(
        valueListenable: mode,
        builder: (context, themeMode, _) => MaterialApp(
          theme: light,
          darkTheme: dark,
          themeMode: themeMode,
          localizationsDelegates: navisLocalizationsDelegates,
          home: Builder(
            builder: (context) {
              opener = context;
              return const Scaffold();
            },
          ),
        ),
      ),
    );

    unawaited(
      showBatteryOptimizationSheet(opener, onOpenSettings: () async {}),
    );
    await tester.pumpAndSettle();

    Color sheetColor() {
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(Material),
            )
            .first,
      );
      return material.color!;
    }

    expect(sheetColor(), dark.colorScheme.surfaceContainerLow);

    mode.value = ThemeMode.light;
    await tester.pumpAndSettle();

    expect(sheetColor(), light.colorScheme.surfaceContainerLow);
    expect(sheetColor(), isNot(dark.colorScheme.surfaceContainerLow));
  });
}
