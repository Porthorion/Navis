import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/equalizer/presentation/eq_band_inspector.dart';

import '../../../../helpers/test_theme.dart';

Future<void> _pumpTile(WidgetTester tester, double width) => tester.pumpWidget(
  MaterialApp(
    theme: testTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: EqParameterTile(
            parameter: EqParameter.q,
            value: 0.667,
            fixed: true,
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('a wide fixed tile shows the "Fixed" text', (tester) async {
    await _pumpTile(tester, 200);
    expect(find.textContaining('Fixed', findRichText: true), findsOneWidget);
  });

  testWidgets('a narrow fixed tile keeps the value whole', (tester) async {
    await _pumpTile(tester, 90);
    expect(find.textContaining('Fixed', findRichText: true), findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
