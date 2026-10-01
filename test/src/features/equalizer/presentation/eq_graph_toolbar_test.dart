import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_editor.dart';

import '../../../../helpers/test_theme.dart';

Future<void> _pumpGraph(WidgetTester tester, double width) async {
  await tester.binding.setSurfaceSize(Size(width + 40, 700));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: testTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            height: 520,
            child: EqGraphEditor(
              configuration: EqConfiguration.flat(),
              selectedBand: 0,
              onSelect: (_) {},
              onBegin: () {},
              onChanged: (_) {},
              onCommit: () {},
              onCancel: () {},
              onPreampInput: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

bool _preampLabelFits(WidgetTester tester) {
  final label = find.descendant(
    of: find.byKey(const ValueKey('eq-input-preamp')),
    matching: find.byType(RichText),
  );
  return !tester.renderObject<RenderParagraph>(label.first).didExceedMaxLines;
}

void main() {
  testWidgets('the 1000 px desktop graph keeps the preamp label whole', (
    tester,
  ) async {
    await _pumpGraph(tester, 590);
    expect(find.byKey(const ValueKey('eq-input-preamp')), findsOneWidget);
    expect(_preampLabelFits(tester), isTrue);
    // Fit and Output are icon buttons here.
    expect(find.byType(FilterChip), findsNothing);
  });

  // flutter_test's square glyphs are wider than Inter, so a wide graph here
  // stands in for the 1440 px desktop layout (checked in an app screenshot).
  testWidgets('a wide graph keeps the preamp slider and text buttons', (
    tester,
  ) async {
    await _pumpGraph(tester, 760);
    expect(find.byKey(const ValueKey('eq-graph-preamp')), findsOneWidget);
    expect(find.byType(FilterChip), findsOneWidget);
    expect(_preampLabelFits(tester), isTrue);
  });
}
