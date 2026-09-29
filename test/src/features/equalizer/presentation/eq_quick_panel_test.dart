import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/domain/eq_workspace.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_editor.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_painter.dart';
import 'package:navis/src/features/equalizer/presentation/eq_quick_panel.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/fake_eq_controller.dart';
import '../../../../helpers/test_theme.dart';

void main() {
  test('compact graphs fit gentle curves to a 12 dB floor', () {
    final bass = EqPreset.builtIns
        .firstWhere((preset) => preset.id == 'builtin:bass')
        .configuration;
    final samples = EqGraphSamples(bass, 48000, null);
    expect(samples.fittedLimit, 24);
    expect(samples.fittedLimitAtLeast(12), 12);
    expect(samples.fittedLimitAtLeast(6), 6);
  });

  final imported = EqPreset(
    id: 'user:hd650',
    name: 'HD 650',
    configuration: EqConfiguration.flat(),
    source: const EqSource(
      originalText: 'Preamp: -6 dB',
      url: 'autoeq://hd650',
    ),
  );

  Future<FakeEqController> pump(
    WidgetTester tester, {
    EqState? initial,
    EqQuickLayout layout = EqQuickLayout.panel,
    Widget? child,
    VoidCallback? onOpen,
    double textScale = 1,
  }) async {
    final fake = FakeEqController(initial: initial);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioHandlerProvider.overrideWithValue(null),
          eqCapabilitiesProvider.overrideWithValue(EqCapabilities.available),
          equalizerProvider.overrideWith(() => fake),
        ],
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child:
                  child ??
                  EqQuickControls(layout: layout, onOpenFullPage: onOpen),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return fake;
  }

  EqState state({
    bool enabled = false,
    String? selected,
    Map<String, EqWorkspace> workspaces = const {},
    String? failure,
  }) => EqState(
    configuration: EqConfiguration.flat().copyWith(enabled: enabled),
    presets: [imported],
    selectedPresetId: selected,
    workspaces: workspaces,
    failure: failure,
  );

  DropdownMenu<String> picker(WidgetTester tester) =>
      tester.widget<DropdownMenu<String>>(
        find.byKey(const ValueKey('eq-quick-preset')),
      );

  String pickerText(WidgetTester tester) => tester
      .widget<TextField>(
        find.descendant(
          of: find.byKey(const ValueKey('eq-quick-preset')),
          matching: find.byType(TextField),
        ),
      )
      .controller!
      .text;

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const ValueKey('eq-quick-preset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('choosing a preset while off selects it and turns the EQ on', (
    tester,
  ) async {
    final fake = await pump(tester, initial: state(selected: 'builtin:flat'));
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('eq-quick-graph-opacity')),
          )
          .opacity,
      0.4,
    );
    expect(pickerText(tester), 'Flat');
    await choose(tester, 'Bass boost');
    expect(fake.calls, ['select:builtin:bass:true']);
    expect(pickerText(tester), 'Bass boost');
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('eq-quick-graph-opacity')),
          )
          .opacity,
      1,
    );
  });

  testWidgets('re-choosing the selected preset only turns the EQ on', (
    tester,
  ) async {
    final fake = await pump(tester, initial: state(selected: 'builtin:flat'));
    await choose(tester, 'Flat');
    expect(fake.calls, ['enable:true']);
  });

  testWidgets('presets order custom drafts, yours, then built-ins', (
    tester,
  ) async {
    await pump(
      tester,
      initial: state(
        enabled: true,
        selected: 'builtin:flat',
        workspaces: {
          eqCustomWorkspace: EqWorkspace.fromConfiguration(
            EqConfiguration.flat().copyWith(preampDb: -3),
          ),
        },
      ),
    );
    final entries = picker(tester).dropdownMenuEntries;
    expect(entries.map((entry) => entry.value), [
      eqCustomWorkspace,
      'user:hd650',
      'builtin:flat',
      'builtin:bass',
      'builtin:vocal',
    ]);
    expect(entries.first.label, 'Custom*');
    expect(
      entries.map((entry) => (entry.leadingIcon! as Icon).icon),
      [
        Icons.edit_outlined,
        Icons.headphones_outlined,
        Icons.graphic_eq,
        Icons.graphic_eq,
        Icons.graphic_eq,
      ],
    );
  });

  testWidgets('without a draft, Custom only appears while selected', (
    tester,
  ) async {
    await pump(tester, initial: state(selected: 'builtin:flat'));
    expect(
      picker(tester).dropdownMenuEntries.map((entry) => entry.value),
      isNot(contains(eqCustomWorkspace)),
    );
  });

  testWidgets('the picker is disabled while a change is applying', (
    tester,
  ) async {
    await pump(
      tester,
      initial: state(selected: 'builtin:flat').copyWith(pending: true),
    );
    expect(picker(tester).enabled, isFalse);
  });

  testWidgets('graph is larger in the panel than in the inline card', (
    tester,
  ) async {
    await pump(tester, initial: state(selected: 'builtin:flat'));
    expect(
      tester.getSize(find.byType(EqGraphEditor)).height,
      176,
    );
    await pump(
      tester,
      initial: state(selected: 'builtin:flat'),
      layout: EqQuickLayout.inline,
    );
    expect(
      tester.getSize(find.byType(EqGraphEditor)).height,
      136,
    );
  });

  testWidgets('failure offers Retry and the graph opens the full page', (
    tester,
  ) async {
    var opened = 0;
    final fake = await pump(
      tester,
      initial: state(failure: 'Could not apply equalizer'),
      onOpen: () => opened++,
    );
    expect(find.text('Could not apply equalizer'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(fake.calls, ['retry']);
    await tester.tap(find.byKey(const ValueKey('eq-quick-graph')));
    expect(opened, 1);
  });

  testWidgets('switch toggles the EQ and card links to the full page', (
    tester,
  ) async {
    var opened = 0;
    final fake = await pump(
      tester,
      initial: state(enabled: true, selected: 'builtin:bass'),
      child: EqQuickCard(onOpenFullPage: () => opened++),
    );
    expect(find.text('Bass boost · Waiting for audio'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('eq-quick-enable')));
    await tester.pumpAndSettle();
    expect(fake.calls, ['enable:false']);
    await tester.tap(find.byKey(const ValueKey('eq-quick-open-page')));
    expect(opened, 1);
    expect(find.byKey(const ValueKey('eq-quick-preset')), findsOneWidget);
  });

  for (final size in [const Size(320, 640), const Size(390, 844)]) {
    testWidgets('inline card fits $size at 200 percent text', (tester) async {
      setAdaptiveTestViewport(tester, size);
      await pump(
        tester,
        initial: state(enabled: true, selected: 'user:hd650'),
        child: const EqQuickCard(),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
