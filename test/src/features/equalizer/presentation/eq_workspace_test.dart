import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_geometry.dart';

import '../../../../helpers/test_database.dart';
import 'eq_test_harness.dart';

const _desktop = Size(1280, 900);

ChoiceChip _chip(WidgetTester tester, int index) => tester.widget<ChoiceChip>(
  find.descendant(
    of: find.byKey(ValueKey('eq-band-chip-$index')),
    matching: find.byType(ChoiceChip),
  ),
);

Offset _handle(WidgetTester tester, EqFilter filter) {
  final plot = tester.getRect(find.byKey(const ValueKey('eq-graph-plot')));
  return plot.topLeft + EqGraphGeometry.inside(plot.size).handle(filter);
}

void main() {
  testWidgets('a drag on stacked handles moves the band chosen in the strip', (
    tester,
  ) async {
    final container = await mount(
      tester,
      size: _desktop,
      desktop: true,
      configuration: EqConfiguration(
        mode: EqMode.advanced,
        filters: const [
          EqFilter(frequencyHz: 1000),
          EqFilter(frequencyHz: 1001),
        ],
      ),
    );
    await tester.tap(find.byKey(const ValueKey('eq-band-chip-1')));
    await tester.pumpAndSettle();
    expect(_chip(tester, 1).selected, isTrue);
    final gesture = await tester.startGesture(
      _handle(tester, const EqFilter(frequencyHz: 1000)),
    );
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -20));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing);
    final filters = container
        .read(equalizerProvider)
        .requireValue
        .configuration
        .filters;
    expect(filters[0].gainDb, 0);
    expect(filters[1].gainDb, greaterThan(0));
    expect(filters[1].frequencyHz, 1001);
  }, skip: !sqliteAvailable);

  testWidgets('a tap selects a clearly nearest band without a chooser', (
    tester,
  ) async {
    await mount(
      tester,
      size: _desktop,
      desktop: true,
      configuration: EqConfiguration(
        mode: EqMode.advanced,
        filters: const [
          EqFilter(frequencyHz: 1000),
          EqFilter(frequencyHz: 1200),
        ],
      ),
    );
    await tester.tapAt(_handle(tester, const EqFilter(frequencyHz: 1200)));
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing);
    expect(_chip(tester, 1).selected, isTrue);
    expect(_chip(tester, 0).selected, isFalse);
  }, skip: !sqliteAvailable);

  testWidgets('fixed layouts lock frequency and Q; pass filters have no gain', (
    tester,
  ) async {
    final container = await mount(
      tester,
      configuration: EqConfiguration.flat(mode: EqMode.tenBand),
    );
    TextButton tile(String parameter) =>
        tester.widget<TextButton>(find.byKey(ValueKey('eq-input-$parameter')));
    expect(tile('frequency').onPressed, isNull);
    expect(tile('q').onPressed, isNull);
    expect(tile('gain').onPressed, isNotNull);
    // Narrow tiles leave out the "Fixed" text; the lock icon (and the
    // semantics label, checked below) still mark both fixed values.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('eq-input-frequency')),
        matching: find.byIcon(Icons.lock_outline),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('eq-input-q')),
        matching: find.byIcon(Icons.lock_outline),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('eq-graph-q')), findsNothing);
    await container
        .read(equalizerProvider.notifier)
        .setConfiguration(
          EqConfiguration(
            mode: EqMode.advanced,
            filters: const [
              EqFilter(type: EqFilterType.highPass, frequencyHz: 80),
            ],
          ),
        );
    await tester.pumpAndSettle();
    expect(tile('gain').onPressed, isNull);
    expect(find.text('Not applicable'), findsOneWidget);
    expect(tile('frequency').onPressed, isNotNull);
    expect(find.byKey(const ValueKey('eq-graph-q')), findsOneWidget);
  }, skip: !sqliteAvailable);

  for (final (size, desktop, scale) in [
    (const Size(390, 844), false, 1.0),
    (const Size(390, 844), false, 2.0),
    (const Size(780, 360), false, 1.0),
    (const Size(800, 600), true, 1.0),
    (_desktop, true, 1.0),
  ]) {
    testWidgets('preamp has exactly one control at $size scale=$scale', (
      tester,
    ) async {
      await mount(tester, size: size, desktop: desktop, scale: scale);
      final preamp = find.byKey(
        const ValueKey('eq-input-preamp'),
        skipOffstage: false,
      );
      if (preamp.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('eq-input-preamp')),
          100,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('eq-band-controls')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
      }
      expect(preamp, findsOneWidget);
      expect(tester.takeException(), isNull);
    }, skip: !sqliteAvailable);
  }

  testWidgets('the Q control changes only Q and forms one Undo step', (
    tester,
  ) async {
    final container = await mount(tester);
    final before = container.read(equalizerProvider).requireValue.configuration;
    await tester.drag(
      find.byKey(const ValueKey('eq-graph-q')),
      const Offset(60, 0),
    );
    await tester.pumpAndSettle();
    final after = container
        .read(equalizerProvider)
        .requireValue
        .configuration
        .filters
        .single;
    expect(after.q, greaterThan(before.filters.single.q));
    expect(after.frequencyHz, before.filters.single.frequencyHz);
    expect(after.gainDb, before.filters.single.gainDb);
    final controller = container.read(equalizerProvider.notifier);
    await controller.undo();
    expect(
      container.read(equalizerProvider).requireValue.configuration,
      before,
    );
    expect(controller.canUndo, isFalse);
  }, skip: !sqliteAvailable);

  testWidgets('the mouse wheel over a band adjusts Q as one Undo step', (
    tester,
  ) async {
    final container = await mount(tester, size: _desktop, desktop: true);
    final before = container.read(equalizerProvider).requireValue.configuration;
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    final position = _handle(tester, before.filters.single);
    await tester.sendEventToBinding(pointer.hover(position));
    for (var i = 0; i < 3; i++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final q = container
        .read(equalizerProvider)
        .requireValue
        .configuration
        .filters
        .single
        .q;
    expect(
      q,
      closeTo(
        EqGraphGeometry.qAt(
          EqGraphGeometry.qPosition(before.filters.single.q) + .15,
        ),
        1e-9,
      ),
    );
    final controller = container.read(equalizerProvider.notifier);
    await controller.undo();
    expect(
      container.read(equalizerProvider).requireValue.configuration,
      before,
    );
    expect(controller.canUndo, isFalse);
  }, skip: !sqliteAvailable);

  testWidgets('a resting wheel session never ends a following Q drag', (
    tester,
  ) async {
    final container = await mount(tester, size: _desktop, desktop: true);
    final before = container.read(equalizerProvider).requireValue.configuration;
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(_handle(tester, before.filters.single)),
    );
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
    await tester.pump(const Duration(milliseconds: 50));
    final wheeled = container
        .read(equalizerProvider)
        .requireValue
        .configuration
        .filters
        .single
        .q;
    final slider = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('eq-graph-q'))),
    );
    await slider.moveBy(const Offset(30, 0));
    await tester.pump(const Duration(milliseconds: 600));
    final midway = container
        .read(equalizerProvider)
        .requireValue
        .configuration
        .filters
        .single
        .q;
    await slider.moveBy(const Offset(30, 0));
    await tester.pump();
    await slider.up();
    await tester.pumpAndSettle();
    final dragged = container
        .read(equalizerProvider)
        .requireValue
        .configuration
        .filters
        .single
        .q;
    expect(midway, isNot(wheeled));
    expect(dragged, greaterThan(midway), reason: 'the slider kept editing');
    final controller = container.read(equalizerProvider.notifier);
    await controller.undo();
    expect(
      container
          .read(equalizerProvider)
          .requireValue
          .configuration
          .filters
          .single
          .q,
      wheeled,
    );
    await controller.undo();
    expect(
      container.read(equalizerProvider).requireValue.configuration,
      before,
    );
  }, skip: !sqliteAvailable);

  testWidgets('Add band creates and selects a neutral 1 kHz peaking band', (
    tester,
  ) async {
    final container = await mount(tester, size: _desktop, desktop: true);
    await tester.tap(find.byKey(const ValueKey('eq-add-band')));
    await tester.pumpAndSettle();
    final filters = container
        .read(equalizerProvider)
        .requireValue
        .configuration
        .filters;
    expect(filters, hasLength(2));
    expect(filters.last, const EqFilter(frequencyHz: 1000));
    expect(filters.last.q, 1);
    expect(_chip(tester, 1).selected, isTrue);
  }, skip: !sqliteAvailable);

  testWidgets('draft status and Save follow the preset identity', (
    tester,
  ) async {
    final container = await mount(tester, size: _desktop, desktop: true);
    expect(find.textContaining('Draft saved on this device'), findsOneWidget);
    expect(find.text('Save as New'), findsOneWidget);
    expect(find.text('Discard'), findsOneWidget);
    final controller = container.read(equalizerProvider.notifier);
    await controller.saveAs('Studio monitors');
    await tester.pumpAndSettle();
    expect(find.textContaining('Studio monitors'), findsWidgets);
    expect(find.byKey(const ValueKey('eq-save')), findsNothing);
    expect(find.textContaining('Draft saved on this device'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('eq-input-gain')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('eq-edit-gain')), '-2');
    await tester.tap(find.byKey(const ValueKey('eq-number-done')));
    await tester.pumpAndSettle();
    expect(find.text('Studio monitors*'), findsOneWidget);
    expect(find.text('Save changes'), findsOneWidget);
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('eq-save')), findsNothing);
    expect(
      container
          .read(equalizerProvider)
          .requireValue
          .selected!
          .configuration
          .filters
          .single
          .gainDb,
      -2,
    );
  }, skip: !sqliteAvailable);

  testWidgets('every band of a dense profile is reachable from the strip', (
    tester,
  ) async {
    final dense = EqConfiguration(
      mode: EqMode.advanced,
      filters: [
        for (var i = 0; i < 32; i++)
          EqFilter(
            frequencyHz: (20 * math.pow(1000, i / 31)).toDouble(),
            gainDb: -.2,
            enabled: i != 30,
          ),
      ],
    );
    final container = await mount(tester, configuration: dense);
    final strip = find.descendant(
      of: find.byKey(const ValueKey('eq-band-strip')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('eq-band-chip-30')),
      150,
      scrollable: strip,
    );
    await tester.tap(find.byKey(const ValueKey('eq-band-chip-30')));
    await tester.pumpAndSettle();
    expect(_chip(tester, 30).selected, isTrue);
    await tester.tap(find.byKey(const ValueKey('eq-input-gain')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('eq-edit-gain')), '1.5');
    await tester.tap(find.byKey(const ValueKey('eq-number-done')));
    await tester.pumpAndSettle();
    final band = container
        .read(equalizerProvider)
        .requireValue
        .configuration
        .filters[30];
    expect(band.gainDb, 1.5);
    expect(band.enabled, isFalse);
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);

  testWidgets('landscape phones place the band inspector beside the graph', (
    tester,
  ) async {
    await mount(tester, size: const Size(780, 360));
    final graph = tester.getRect(find.byKey(const ValueKey('eq-graph-plot')));
    final inspector = tester.getRect(
      find.byKey(const ValueKey('eq-band-controls')),
    );
    expect(inspector.left, greaterThan(graph.right));
    expect(graph.height, greaterThan(120));
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);

  testWidgets('short wide layouts keep band values in view', (tester) async {
    const size = Size(900, 340);
    await mount(tester, size: size, desktop: true);
    expect(find.byKey(const ValueKey('eq-band-strip')), findsOneWidget);
    for (final parameter in ['frequency', 'gain', 'q']) {
      final tile = tester.getRect(find.byKey(ValueKey('eq-input-$parameter')));
      expect(tile.bottom, lessThanOrEqualTo(size.height), reason: parameter);
    }
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);

  testWidgets('numeric entry locks selection and mode until resolved', (
    tester,
  ) async {
    final container = await mount(tester, size: _desktop, desktop: true);
    final before = container.read(equalizerProvider).requireValue.configuration;
    await tester.tap(find.byKey(const ValueKey('eq-input-gain')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('eq-band-controls')), findsNothing);
    await tester.tap(find.text('Simple'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      container.read(equalizerProvider).requireValue.configuration.mode,
      EqMode.advanced,
    );
    await tester.enterText(find.byKey(const ValueKey('eq-edit-gain')), '9');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('eq-edit-gain')), findsNothing);
    expect(
      container.read(equalizerProvider).requireValue.configuration,
      before,
    );
  }, skip: !sqliteAvailable);

  testWidgets('the pinned preset library is locked during exact entry', (
    tester,
  ) async {
    final container = await mount(
      tester,
      size: const Size(1400, 900),
      desktop: true,
    );
    await tester.tap(find.byKey(const ValueKey('eq-preset-picker')));
    await tester.pumpAndSettle();
    final bass = find.byKey(const ValueKey('eq-preset-builtin:bass'));
    expect(bass, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('eq-input-gain')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('eq-edit-gain')), '-4.5');
    await tester.tap(bass, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      container.read(equalizerProvider).requireValue.selectedPresetId,
      isNot('builtin:bass'),
    );
    await tester.tap(find.byKey(const ValueKey('eq-number-done')));
    await tester.pumpAndSettle();
    expect(
      container
          .read(equalizerProvider)
          .requireValue
          .configuration
          .filters
          .single
          .gainDb,
      -4.5,
    );
  }, skip: !sqliteAvailable);

  testWidgets('exact entry accepts a comma decimal separator', (tester) async {
    final container = await mount(tester, size: _desktop, desktop: true);
    await tester.tap(find.byKey(const ValueKey('eq-input-gain')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('eq-edit-gain')), '-4,5');
    await tester.tap(find.byKey(const ValueKey('eq-number-done')));
    await tester.pumpAndSettle();
    expect(
      container
          .read(equalizerProvider)
          .requireValue
          .configuration
          .filters
          .single
          .gainDb,
      -4.5,
    );
  }, skip: !sqliteAvailable);

  testWidgets('typing keeps the caret where the user placed it', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('eq-input-gain')));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('eq-edit-gain'));
    await tester.enterText(field, '12');
    await tester.pump();
    final controller = tester
        .widget<EditableText>(
          find.descendant(of: field, matching: find.byType(EditableText)),
        )
        .controller;
    expect(controller.selection, const TextSelection.collapsed(offset: 2));
    await tester.tap(find.byKey(const ValueKey('eq-number-cancel')));
    await tester.pumpAndSettle();
  }, skip: !sqliteAvailable);

  testWidgets('bands, values and fixed parameters are announced', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await mount(tester, configuration: EqConfiguration.flat());
    expect(
      find.bySemanticsLabel(RegExp('^Band 3, 1000 Hz, Peaking · 0 dB')),
      findsWidgets,
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('eq-input-gain'))),
      matchesSemantics(
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
        label: 'Gain\n0 dB',
        hint: 'Tap to enter an exact value',
      ),
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('eq-input-frequency'))),
      matchesSemantics(
        isButton: true,
        hasEnabledState: true,
        label: 'Frequency\n63 Hz · Fixed',
        hint: 'Fixed in this mode. Use Edit in Advanced to change it.',
      ),
    );
    semantics.dispose();
  }, skip: !sqliteAvailable);
}
