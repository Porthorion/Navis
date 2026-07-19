import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/presentation/desktop_shortcuts_settings_screen.dart';
import 'package:navis/src/routing/desktop_commands.dart';

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
}
