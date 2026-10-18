import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/preset_picker.dart';

const _labels = PresetPickerLabels(
  picker: 'Preset',
  custom: 'Custom',
  actions: 'Preset actions',
  saveNew: 'Save as new',
  update: _update,
  rename: _rename,
  delete: _delete,
  deleteConfirm: _confirm,
  renameTitle: 'Rename preset',
  nameField: 'Preset Name',
  cancel: 'Cancel',
  save: 'Save',
  deleteAction: 'Delete',
  discard: 'Discard Changes',
  discardShort: 'Discard',
  discardConfirm: _discard,
);

String _update(String name) => 'Update "$name"';
String _rename(String name) => 'Rename "$name"…';
String _delete(String name) => 'Delete "$name"';
String _confirm(String name) => 'Delete "$name"?';
String _discard(String name) => 'Back to "$name"?';

const _entries = [
  PresetPickerEntry(id: 'none', label: 'Normal', icon: Icons.restart_alt),
  PresetPickerEntry(id: 'a', label: 'Alpha'),
  PresetPickerEntry(
    id: 'b',
    label: 'Beta',
    enabled: false,
    disabledReason: 'Not available here',
  ),
];

Finder _key(String name) => find.byKey(ValueKey<String>('test$name'));

void main() {
  final calls = <String>[];
  String? saveError;

  setUp(() {
    calls.clear();
    saveError = null;
  });

  Future<void> pump(
    WidgetTester tester, {
    String? selectedId,
    String? updateId,
    String? manageId,
    bool enabled = true,
    bool withUpdate = true,
    bool withDiscard = true,
    List<PresetPickerEntry> entries = _entries,
    double width = 800,
    double textScale = 1,
  }) => tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: PresetPicker(
            keyPrefix: 'test',
            entries: entries,
            selectedId: selectedId,
            updateId: updateId,
            manageId: manageId,
            enabled: enabled,
            icon: Icons.speed,
            labels: _labels,
            onSelect: (id) async => calls.add('select $id'),
            onSaveNew: (name) async {
              calls.add('save $name');
              return saveError;
            },
            onUpdate: withUpdate ? (id) async => calls.add('update $id') : null,
            onDiscard: withDiscard
                ? (id) async => calls.add('discard $id')
                : null,
            onRename: (id, name) async {
              calls.add('rename $id $name');
              return saveError;
            },
            onDelete: (id) async => calls.add('delete $id'),
          ),
        ),
      ),
    ),
  );

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(_key('Actions'));
    await tester.pumpAndSettle();
  }

  Future<void> menuAction(WidgetTester tester, String name) async {
    await openMenu(tester);
    await tester.tap(_key(name));
    await tester.pumpAndSettle();
  }

  String shown(WidgetTester tester) => tester
      .widget<TextField>(
        find.descendant(of: _key('Dropdown'), matching: find.byType(TextField)),
      )
      .controller!
      .text;

  group('edited preset', () {
    testWidgets('reads <name>* while edited, plain Custom without an origin', (
      tester,
    ) async {
      await pump(tester, updateId: 'a');
      expect(shown(tester), 'Alpha*');
      await pump(tester);
      await tester.pumpAndSettle();
      expect(shown(tester), 'Custom');
      await pump(tester, selectedId: 'a', updateId: 'a');
      await tester.pumpAndSettle();
      expect(shown(tester), 'Alpha');
    });

    testWidgets('a visible Discard shows only while edited and asks first', (
      tester,
    ) async {
      await pump(tester, selectedId: 'a', updateId: 'a');
      expect(_key('Discard'), findsNothing);
      await pump(tester, updateId: 'a', withDiscard: false);
      await tester.pumpAndSettle();
      expect(_key('Discard'), findsNothing);
      // No origin: nothing to go back to.
      await pump(tester);
      await tester.pumpAndSettle();
      expect(_key('Discard'), findsNothing);

      await pump(tester, updateId: 'a');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextButton, 'Discard'), findsOneWidget);
      await tester.tap(_key('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('Back to "Alpha"?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);

      await tester.tap(_key('Discard'));
      await tester.pumpAndSettle();
      await tester.tap(_key('DiscardConfirm'));
      await tester.pumpAndSettle();
      expect(calls, ['discard a']);
    });

    testWidgets('Discard becomes an icon button when space is tight', (
      tester,
    ) async {
      await pump(tester, updateId: 'a', width: 320);
      await tester.pumpAndSettle();
      expect(find.widgetWithIcon(IconButton, Icons.restore), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Discard'), findsNothing);
      await tester.tap(_key('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('Back to "Alpha"?'), findsOneWidget);
    });

    testWidgets('Discard is hidden when the origin is unavailable', (
      tester,
    ) async {
      // Beta is disabled (unsupported here), so it cannot be re-applied.
      await pump(tester, updateId: 'b');
      await tester.pumpAndSettle();
      expect(shown(tester), 'Beta*');
      expect(_key('Discard'), findsNothing);
    });

    testWidgets('a long name still wraps at twice the text size', (
      tester,
    ) async {
      const long = PresetPickerEntry(
        id: 'long',
        label: 'RP150 Green Teal Night Variant With A Long Name',
      );
      const short = PresetPickerEntry(id: 'short', label: 'Short');
      double height(WidgetTester tester) => tester
          .getSize(
            find.descendant(
              of: _key('Dropdown'),
              matching: find.byType(TextField),
            ),
          )
          .height;
      await pump(
        tester,
        selectedId: 'short',
        entries: [short],
        width: 360,
        textScale: 2,
      );
      await tester.pumpAndSettle();
      final one = height(tester);
      await pump(
        tester,
        selectedId: 'long',
        entries: [long],
        width: 360,
        textScale: 2,
      );
      await tester.pumpAndSettle();
      expect(shown(tester), long.label);
      // Three lines at most, and taller than one: wrapped, not cut off.
      expect(height(tester), greaterThan(one + 20));
    });

    testWidgets('a long name wraps instead of being cut off', (tester) async {
      const long = PresetPickerEntry(
        id: 'long',
        label: 'RP150 Green Teal Night Variant With A Long Name',
      );
      await pump(tester, selectedId: 'long', entries: [long], width: 300);
      await tester.pumpAndSettle();
      expect(shown(tester), long.label);
      // Taller than the 56 dp single-line field: wrapped, not cut off.
      expect(
        tester
            .getSize(
              find.descendant(
                of: _key('Dropdown'),
                matching: find.byType(TextField),
              ),
            )
            .height,
        greaterThan(60),
      );
    });
  });

  group('dropdown', () {
    testWidgets('lists Custom only while nothing is selected', (tester) async {
      await pump(tester);
      expect(shown(tester), 'Custom');
      await tester.tap(_key('Dropdown'));
      await tester.pumpAndSettle();
      expect(find.text('Custom'), findsWidgets);
      expect(find.text('Normal'), findsOneWidget);

      await pump(tester, selectedId: 'a');
      await tester.pumpAndSettle();
      expect(shown(tester), 'Alpha');
      final menu = tester.widget<DropdownMenu<String>>(_key('Dropdown'));
      expect(menu.dropdownMenuEntries.map((e) => e.label), [
        'Normal',
        'Alpha',
        'Beta',
      ]);
    });

    testWidgets('selecting another entry reports it, the same one does not', (
      tester,
    ) async {
      await pump(tester, selectedId: 'a');
      await tester.tap(_key('Dropdown'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alpha').last);
      await tester.pumpAndSettle();
      expect(calls, isEmpty);

      await tester.tap(_key('Dropdown'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Normal').last);
      await tester.pumpAndSettle();
      expect(calls, ['select none']);
    });

    testWidgets('a disabled entry explains itself and cannot be chosen', (
      tester,
    ) async {
      await pump(tester, selectedId: 'a');
      final menu = tester.widget<DropdownMenu<String>>(_key('Dropdown'));
      final beta = menu.dropdownMenuEntries.singleWhere((e) => e.value == 'b');
      expect(beta.enabled, isFalse);
      expect((beta.trailingIcon! as Tooltip).message, 'Not available here');
      expect(
        menu.dropdownMenuEntries.singleWhere((e) => e.value == 'a').enabled,
        isTrue,
      );
    });

    testWidgets('disabling the picker disables the dropdown and the menu', (
      tester,
    ) async {
      await pump(tester, enabled: false);
      expect(
        tester.widget<DropdownMenu<String>>(_key('Dropdown')).enabled,
        isFalse,
      );
      expect(tester.widget<IconButton>(_key('Actions')).onPressed, isNull);
    });
  });

  group('actions menu', () {
    testWidgets('offers only Save as new without a target', (tester) async {
      await pump(tester);
      await openMenu(tester);
      expect(_key('SaveNew'), findsOneWidget);
      expect(_key('Update'), findsNothing);
      expect(_key('Rename'), findsNothing);
      expect(_key('Delete'), findsNothing);
    });

    testWidgets('names the preset each action targets', (tester) async {
      await pump(tester, selectedId: 'none', updateId: 'a', manageId: 'a');
      await openMenu(tester);
      expect(find.text('Update "Alpha"'), findsOneWidget);
      expect(find.text('Rename "Alpha"…'), findsOneWidget);
      expect(find.text('Delete "Alpha"'), findsOneWidget);
    });

    testWidgets('Update needs both a target and a callback', (tester) async {
      await pump(tester, updateId: 'a', withUpdate: false);
      await openMenu(tester);
      expect(_key('Update'), findsNothing);
    });

    testWidgets('Update overwrites the origin preset', (tester) async {
      await pump(tester, updateId: 'a', manageId: 'a');
      await menuAction(tester, 'Update');
      expect(calls, ['update a']);
    });
  });

  group('names', () {
    testWidgets('Save as new reports the typed name and closes', (
      tester,
    ) async {
      await pump(tester);
      await menuAction(tester, 'SaveNew');
      await tester.enterText(_key('NameInput'), 'Brisk');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(calls, ['save Brisk']);
      expect(_key('NameInput'), findsNothing);
    });

    testWidgets('a refused name stays open with the error inline', (
      tester,
    ) async {
      saveError = 'Name already used';
      await pump(tester);
      await menuAction(tester, 'SaveNew');
      await tester.enterText(_key('NameInput'), 'Alpha');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Name already used'), findsOneWidget);
      expect(_key('NameInput'), findsOneWidget);

      saveError = null;
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(calls, ['save Alpha', 'save Alpha']);
      expect(_key('NameInput'), findsNothing);
    });

    testWidgets('Cancel closes without saving', (tester) async {
      await pump(tester);
      await menuAction(tester, 'SaveNew');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(_key('NameInput'), findsNothing);
    });

    testWidgets('Rename starts from the current name', (tester) async {
      await pump(tester, selectedId: 'a', manageId: 'a');
      await menuAction(tester, 'Rename');
      expect(find.text('Rename preset'), findsOneWidget);
      expect(
        tester.widget<TextField>(_key('NameInput')).controller!.text,
        'Alpha',
      );
      await tester.enterText(_key('NameInput'), 'Omega');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(calls, ['rename a Omega']);
    });

    testWidgets('a refused rename shows its error', (tester) async {
      saveError = 'Too long';
      await pump(tester, selectedId: 'a', manageId: 'a');
      await menuAction(tester, 'Rename');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Too long'), findsOneWidget);
    });
  });

  group('delete', () {
    testWidgets('asks first, then deletes the target', (tester) async {
      await pump(tester, selectedId: 'a', manageId: 'a');
      await menuAction(tester, 'Delete');
      expect(find.text('Delete "Alpha"?'), findsOneWidget);
      expect(calls, isEmpty);
      await tester.tap(_key('DeleteConfirm'));
      await tester.pumpAndSettle();
      expect(calls, ['delete a']);
    });

    testWidgets('cancelling keeps the preset', (tester) async {
      await pump(tester, selectedId: 'a', manageId: 'a');
      await menuAction(tester, 'Delete');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(find.text('Delete "Alpha"?'), findsNothing);
    });
  });
}
