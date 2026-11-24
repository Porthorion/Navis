import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart' hide TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_editor.dart';

import 'package:navis/src/theme/navis_theme.dart';

import '../../../../helpers/test_theme.dart';
import 'eq_test_harness.dart';

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

  // The toolbar is chosen by graph width and text scale. Measured with the
  // bundled Inter (flutter_test's Ahem is far too wide), so load it here.
  Future<void> mountInter(
    WidgetTester tester,
    Size size, {
    double scale = 1,
    bool desktop = false,
  }) async {
    final inter = FontLoader(navisFontFamily)
      ..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'));
    await inter.load();
    await mount(
      tester,
      size: size,
      scale: scale,
      desktop: desktop,
      theme: buildLightTheme(Colors.indigo),
    );
  }

  // 700 px: the 668 px graph is roomy at 1.0x and must go compact by 1.3x.
  // 760 and 834 px lay the graph out beside the bands (about 410-490 px).
  for (final size in const [
    Size(700, 1000),
    Size(760, 1000),
    Size(834, 1194),
  ]) {
    for (final scale in const [1.0, 1.3, 1.4]) {
      testWidgets('touch $size at ${scale}x toolbar fits', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          await mountInter(tester, size, scale: scale);
          expect(tester.takeException(), isNull);
          final fit = find.byKey(const ValueKey('eq-fit-response'));
          final roomy = find.byType(FilterChip).evaluate().isNotEmpty;
          expect(
            tester.widget(fit),
            roomy ? isA<TextButton>() : isA<IconButton>(),
          );
          expect(
            find.byKey(const ValueKey('eq-output-response')),
            findsOneWidget,
          );
          if (roomy) {
            final label = find.descendant(
              of: find.byKey(const ValueKey('eq-input-preamp')),
              matching: find.textContaining('Preamp'),
            );
            expect(
              tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
              isFalse,
            );
          }
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }

  testWidgets('desktop 1440x900 keeps the roomy toolbar', (tester) async {
    await mountInter(tester, const Size(1440, 900), desktop: true);
    expect(tester.takeException(), isNull);
    expect(
      tester.widget(find.byKey(const ValueKey('eq-fit-response'))),
      isA<TextButton>(),
    );
  });

  testWidgets('desktop 1000x700 toolbar is unchanged', (tester) async {
    await mountInter(tester, const Size(1000, 700), desktop: true);
    expect(tester.takeException(), isNull);
    expect(
      tester.widget(find.byKey(const ValueKey('eq-fit-response'))),
      isA<TextButton>(),
    );
  });
}
