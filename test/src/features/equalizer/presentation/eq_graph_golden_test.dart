import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_editor.dart';
import 'package:navis/src/theme/navis_theme.dart';

final _parametric = EqConfiguration(
  mode: EqMode.advanced,
  enabled: true,
  preampDb: -5,
  filters: const [
    EqFilter(type: EqFilterType.lowShelf, frequencyHz: 105, gainDb: 5.5, q: .7),
    EqFilter(frequencyHz: 440, gainDb: -3.2, q: 2),
    EqFilter(frequencyHz: 1234.56789, gainDb: 3.12735, q: 1.4142135623730951),
    EqFilter(frequencyHz: 1300, gainDb: 2.5, q: 4, enabled: false),
    EqFilter(
      type: EqFilterType.highShelf,
      frequencyHz: 9000,
      gainDb: -4,
      q: .7,
    ),
    EqFilter(type: EqFilterType.lowPass, frequencyHz: 18000, q: .7),
  ],
);

final _dense = EqConfiguration(
  mode: EqMode.advanced,
  enabled: true,
  filters: [
    for (var i = 0; i < 32; i++)
      EqFilter(
        frequencyHz: (20 * math.pow(1000, i / 31)).toDouble(),
        gainDb: 4 * math.sin(i / 3),
        q: 1.4,
        enabled: i != 7,
      ),
  ],
);

Widget _graph(ThemeData theme, EqConfiguration configuration, int selected) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(8),
          child: EqGraphEditor(
            configuration: configuration,
            selectedBand: selected,
            onSelect: (_) {},
            onBegin: () {},
            onChanged: (_) {},
            onCommit: () {},
            onCancel: () {},
            onPreampInput: () {},
          ),
        ),
      ),
    );

void main() {
  testWidgets('selected filter is filled and distinct in the default theme', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _graph(buildDarkTheme(defaultColorSchemeSeedColor), _parametric, 2),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(EqGraphEditor),
      matchesGoldenFile('goldens/eq_graph_selected_dark_390.png'),
    );
  });

  testWidgets('dense profiles keep the selected band legible', (tester) async {
    await tester.binding.setSurfaceSize(const Size(820, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _graph(buildLightTheme(Colors.teal), _dense, 15),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(EqGraphEditor),
      matchesGoldenFile('goldens/eq_graph_dense_light_820.png'),
    );
  });
}
