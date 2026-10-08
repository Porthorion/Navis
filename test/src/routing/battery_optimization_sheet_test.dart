import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/routing/app_shell.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
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
