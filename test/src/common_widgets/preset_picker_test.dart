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
  nameField: 'Preset name',
  cancel: 'Cancel',
  save: 'Save',
  deleteAction: 'Delete',
);

String _update(String name) => 'Update "$name"';
String _rename(String name) => 'Rename "$name"…';
String _delete(String name) => 'Delete "$name"';
String _confirm(String name) => 'Delete "$name"?';

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
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PresetPicker(
          keyPrefix: 'test',
          entries: _entries,
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
          onRename: (id, name) async {
            calls.add('rename $id $name');
            return saveError;
          },
          onDelete: (id) async => calls.add('delete $id'),
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
