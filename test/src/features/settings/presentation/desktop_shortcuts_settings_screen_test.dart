import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/settings/presentation/desktop_shortcuts_settings_screen.dart';
import 'package:navis/src/routing/desktop_commands.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/test_theme.dart';

void main() {
  testWidgets('captured shortcut saves on Enter', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DesktopShortcutsSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(
        const ValueKey<String>('desktopShortcut-openQuickSearch'),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      container.read(
        desktopShortcutBindingsProvider,
      )[DesktopCommandAction.openQuickSearch],
      const DesktopShortcutBinding(
        key: LogicalKeyboardKey.keyP,
        shift: true,
      ),
    );
  });

  testWidgets('captured shortcut cancels on Escape', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DesktopShortcutsSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final original = container.read(
      desktopShortcutBindingsProvider,
    )[DesktopCommandAction.openQuickSearch];

    await tester.tap(
      find.byKey(
        const ValueKey<String>('desktopShortcut-openQuickSearch'),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(
      container.read(
        desktopShortcutBindingsProvider,
      )[DesktopCommandAction.openQuickSearch],
      original,
    );
  });

  testWidgets('desktop shortcuts use a focused settings workspace', (
    tester,
  ) async {
    setAdaptiveTestViewport(tester, const Size(1280, 800));
    final desktopContext = resolveAdaptiveContext(
      desktopRuntime: true,
      viewportSize: const Size(1280, 800),
      safePadding: EdgeInsets.zero,
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AdaptiveContextScope(
            adaptiveContext: desktopContext,
            child: const DesktopShortcutsSettingsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Back to Settings'), findsOneWidget);
    expect(find.text('Customizable'), findsOneWidget);
    expect(tester.getSize(find.byType(ListView)).width, 1040);
    await expectLater(
      find.byType(DesktopShortcutsSettingsScreen),
      matchesGoldenFile('goldens/desktop_shortcuts_workspace.png'),
    );
  });
}
