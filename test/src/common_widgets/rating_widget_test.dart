import 'dart:ui' show Tristate;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/rating_widget.dart';

String _label(int i) => i == 1 ? 'Rate 1 star' : 'Rate $i stars';

Future<void> _pump(
  WidgetTester tester, {
  required int? rating,
  required ValueChanged<int> onChanged,
  bool compact = false,
}) => tester.pumpWidget(
  MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(
        child: RatingWidget(
          rating: rating,
          compact: compact,
          onChanged: onChanged,
        ),
      ),
    ),
  ),
);

void _expectSelected(WidgetTester tester, int rating) {
  for (var i = 1; i <= 5; i++) {
    final node = tester.getSemantics(find.bySemanticsLabel(_label(i)));
    expect(node.flagsCollection.isButton, isTrue, reason: 'star $i');
    expect(
      node.flagsCollection.isSelected,
      i <= rating ? Tristate.isTrue : Tristate.isFalse,
      reason: 'star $i',
    );
    expect(
      node.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
      reason: 'star $i',
    );
  }
}

void main() {
  testWidgets('each star is a labelled button, selected up to the rating', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, rating: 3, onChanged: (_) {});
    _expectSelected(tester, 3);
    handle.dispose();
  });

  testWidgets('stars meet the 48 px tap target and label guidelines', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, rating: 2, onChanged: (_) {});
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });

  testWidgets('compact stars are still labelled and 48 px tall', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, rating: null, compact: true, onChanged: (_) {});
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    final rect = tester.getSemantics(find.bySemanticsLabel(_label(4))).rect;
    expect(rect.height, greaterThanOrEqualTo(48));
    expect(rect.width, greaterThanOrEqualTo(28));
    handle.dispose();
  });

  testWidgets('tapping a star sets it; tapping the current rating clears', (
    tester,
  ) async {
    final taps = <int>[];
    await _pump(tester, rating: 3, onChanged: taps.add);
    await tester.tap(find.bySemanticsLabel(_label(5)));
    await tester.tap(find.bySemanticsLabel(_label(3)));
    expect(taps, <int>[5, 0]);
  });

  testWidgets('rating 0 and null select no star', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, rating: 0, onChanged: (_) {});
    _expectSelected(tester, 0);
    await _pump(tester, rating: null, onChanged: (_) {});
    _expectSelected(tester, 0);
    handle.dispose();
  });
}
