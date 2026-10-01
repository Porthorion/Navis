import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/equalizer/data/eq_import_parser.dart';
import 'package:navis/src/features/equalizer/presentation/eq_import_dialogs.dart';

import '../../../../helpers/test_theme.dart';

void main() {
  Future<void> show(WidgetTester tester, Widget dialog) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: dialog),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the preview lists what the import could not reproduce', (
    tester,
  ) async {
    final result = EqImportParser().parseText(
      'Device: Speakers\nInclude: room.txt\n'
      'Filter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1\n'
      'Filter 2: ON BP Fc 500 Hz Q 1\n',
      id: 'preview',
      name: 'Speakers',
    );
    await show(
      tester,
      EqImportPreviewDialog(
        preset: result.preset,
        name: 'Speakers',
        warnings: result.warnings,
      ),
    );

    expect(find.text('Notes'), findsOneWidget);
    expect(
      find.text('2 settings that do not affect the curve were ignored.'),
      findsOneWidget,
    );
    expect(
      find.text('1 filter of an unsupported type was left out.'),
      findsOneWidget,
    );
    expect(
      find.text('No preamp was set; automatic headroom prevents clipping.'),
      findsOneWidget,
    );
  });

  testWidgets('a pasted profile with a bad line names the line', (
    tester,
  ) async {
    await show(tester, const EqPasteDialog());
    await tester.enterText(
      find.byType(TextField),
      'Preamp: -3 dB\nFilter 1: ON PK Fc 1000 Hz Gain 99 dB Q 1',
    );
    await tester.tap(find.text('Preview preset'));
    await tester.pumpAndSettle();

    expect(
      find.text('Line 2 has a value outside the supported range.'),
      findsOneWidget,
    );
  });
}
