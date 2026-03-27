import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/routing/desktop_commands.dart';

void main() {
  testWidgets('desktop command guard blocks when text input is focused', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(focusNode: focusNode),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    expect(desktopCommandBlockedByTextInput(), isTrue);
  });

  testWidgets('desktop command guard allows non-text focused widgets', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            focusNode: focusNode,
            child: const SizedBox(height: 20, width: 20),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    expect(desktopCommandBlockedByTextInput(), isFalse);
  });

  test('isTextSensitiveDesktopCommand identifies transport actions', () {
    expect(
      isTextSensitiveDesktopCommand(DesktopCommandAction.playPause),
      isTrue,
    );
    expect(
      isTextSensitiveDesktopCommand(DesktopCommandAction.nextTrack),
      isTrue,
    );
    expect(
      isTextSensitiveDesktopCommand(DesktopCommandAction.previousTrack),
      isTrue,
    );
    expect(
      isTextSensitiveDesktopCommand(DesktopCommandAction.toggleQueue),
      isFalse,
    );
    expect(
      isTextSensitiveDesktopCommand(DesktopCommandAction.openQuickSearch),
      isFalse,
    );
  });

  test('desktop shortcut map can exclude escape binding', () {
    final shortcuts = buildDesktopShortcutMap(
      TargetPlatform.linux,
      includeEscape: false,
    );
    expect(
      shortcuts.containsKey(const SingleActivator(LogicalKeyboardKey.escape)),
      isFalse,
    );
  });

  test('desktop shortcut map includes default quick-search binding', () {
    final shortcuts = buildDesktopShortcutMap(TargetPlatform.linux);
    final hasQuickSearch = shortcuts.values.any(
      (intent) =>
          intent is DesktopCommandIntent &&
          intent.action == DesktopCommandAction.openQuickSearch,
    );
    expect(
      hasQuickSearch,
      isTrue,
    );
  });

  test('primary modifier activator uses meta on macOS', () {
    const binding = DesktopShortcutBinding(key: LogicalKeyboardKey.keyF);

    expect(
      binding.toActivator(TargetPlatform.macOS).toString(),
      contains('Meta + Key F'),
    );
  });

  test('primary modifier activator uses control on Linux and Windows', () {
    const binding = DesktopShortcutBinding(key: LogicalKeyboardKey.keyF);

    expect(
      binding.toActivator(TargetPlatform.linux).toString(),
      contains('Control + Key F'),
    );
    expect(
      binding.toActivator(TargetPlatform.windows).toString(),
      contains('Control + Key F'),
    );
  });

  test('shortcut labels use platform-specific modifier names', () {
    const binding = DesktopShortcutBinding(
      key: LogicalKeyboardKey.keyJ,
      alt: true,
      shift: true,
    );

    expect(binding.formatLabel(TargetPlatform.macOS), 'Cmd+Option+Shift+J');
    expect(binding.formatLabel(TargetPlatform.linux), 'Ctrl+Alt+Shift+J');
    expect(binding.formatLabel(TargetPlatform.windows), 'Ctrl+Alt+Shift+J');
  });

  test('desktop shortcut bindings encode to null when unchanged', () {
    final defaults = defaultDesktopShortcutBindings();
    expect(encodeDesktopShortcutBindings(defaults), isNull);
  });

  test('desktop shortcut bindings decode restores saved overrides', () {
    final updated = Map<DesktopCommandAction, DesktopShortcutBinding?>.from(
      defaultDesktopShortcutBindings(),
    )..[DesktopCommandAction.openQuickSearch] = const DesktopShortcutBinding(
        key: LogicalKeyboardKey.keyP,
      );

    final encoded = encodeDesktopShortcutBindings(updated);
    final decoded = decodeDesktopShortcutBindings(encoded);
    expect(
      decoded[DesktopCommandAction.openQuickSearch],
      const DesktopShortcutBinding(key: LogicalKeyboardKey.keyP),
    );
    expect(
      decoded[DesktopCommandAction.goHome],
      defaultDesktopShortcutBindings()[DesktopCommandAction.goHome],
    );
  });

  testWidgets(
    'transport commands are blocked when typing in a text field',
    (tester) async {
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(focusNode: focusNode),
          ),
        ),
      );

      focusNode.requestFocus();
      await tester.pump();

      // Transport commands should be blocked.
      expect(
        isTextSensitiveDesktopCommand(DesktopCommandAction.playPause) &&
            desktopCommandBlockedByTextInput(),
        isTrue,
      );
      // Non-transport commands should not be blocked.
      expect(
        isTextSensitiveDesktopCommand(DesktopCommandAction.toggleQueue) ||
            desktopCommandBlockedByTextInput(),
        isTrue, // blocked by text, but not text-sensitive
      );
      expect(
        isTextSensitiveDesktopCommand(DesktopCommandAction.toggleQueue),
        isFalse,
      );
    },
  );
}
