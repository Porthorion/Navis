import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
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
        home: Scaffold(body: TextField(focusNode: focusNode)),
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

  test('history shortcuts follow platform browser conventions', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    var bindings = defaultDesktopShortcutBindings();
    expect(
      bindings[DesktopCommandAction.navigateBack],
      const DesktopShortcutBinding(
        key: LogicalKeyboardKey.arrowLeft,
        primaryModifier: false,
        alt: true,
      ),
    );
    expect(
      bindings[DesktopCommandAction.navigateForward],
      const DesktopShortcutBinding(
        key: LogicalKeyboardKey.arrowRight,
        primaryModifier: false,
        alt: true,
      ),
    );

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    bindings = defaultDesktopShortcutBindings();
    expect(
      bindings[DesktopCommandAction.navigateBack],
      const DesktopShortcutBinding(key: LogicalKeyboardKey.bracketLeft),
    );
    expect(
      bindings[DesktopCommandAction.navigateForward],
      const DesktopShortcutBinding(key: LogicalKeyboardKey.bracketRight),
    );
  });

  test('history shortcuts yield to text editing', () {
    expect(
      isTextSensitiveDesktopCommand(DesktopCommandAction.navigateBack),
      isTrue,
    );
    expect(
      isTextSensitiveDesktopCommand(DesktopCommandAction.navigateForward),
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
    final updated =
        Map<DesktopCommandAction, DesktopShortcutBinding?>.from(
            defaultDesktopShortcutBindings(),
          )
          ..[DesktopCommandAction.openQuickSearch] =
              const DesktopShortcutBinding(key: LogicalKeyboardKey.keyP);

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

  test('speed shortcuts are configurable with unique default bindings', () {
    final defaults = defaultDesktopShortcutBindings();
    for (final action in [
      DesktopCommandAction.speedUp,
      DesktopCommandAction.speedDown,
      DesktopCommandAction.speedReset,
    ]) {
      expect(configurableDesktopShortcutActions, contains(action));
      expect(defaults[action], isNotNull);
      expect(isTextSensitiveDesktopCommand(action), isFalse);
    }
    final bindings = defaults.values.whereType<DesktopShortcutBinding>();
    expect(bindings.toSet().length, bindings.length);
    expect(
      defaults[DesktopCommandAction.speedUp]!.formatLabel(TargetPlatform.linux),
      'Ctrl+.',
    );
  });

  test('bindings saved before speed shortcuts existed keep speed defaults', () {
    final decoded = decodeDesktopShortcutBindings(
      jsonEncode(<String, Object?>{'openQuickSearch': null}),
    );
    expect(decoded[DesktopCommandAction.openQuickSearch], isNull);
    expect(
      decoded[DesktopCommandAction.speedUp],
      defaultDesktopShortcutBindings()[DesktopCommandAction.speedUp],
    );
  });

  testWidgets('Ctrl+period and Ctrl+comma match the speed commands', (
    tester,
  ) async {
    DesktopCommandAction? matched;
    bool handler(KeyEvent event) {
      if (event is KeyDownEvent &&
          event.logicalKey != LogicalKeyboardKey.controlLeft) {
        matched = matchAnyDesktopCommandForKeyEvent(
          event,
          TargetPlatform.linux,
          enableShortcuts: true,
          enableEscapeOverlay: false,
        );
      }
      return false;
    }

    HardwareKeyboard.instance.addHandler(handler);
    addTearDown(() => HardwareKeyboard.instance.removeHandler(handler));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.period);
    expect(matched, DesktopCommandAction.speedUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    expect(matched, DesktopCommandAction.speedDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    expect(matched, DesktopCommandAction.speedReset);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  testWidgets('transport commands are blocked when typing in a text field', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextField(focusNode: focusNode)),
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
  });
}
