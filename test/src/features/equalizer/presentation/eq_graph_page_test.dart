import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_geometry.dart';
import 'package:navis/src/features/equalizer/presentation/eq_screen.dart';

import '../../../../helpers/test_database.dart';
import 'eq_test_harness.dart';

void main() {
  for (final (size, desktop, scale, keyboard) in [
    (const Size(390, 844), false, 1.0, false),
    (const Size(390, 844), false, 2.0, true),
    (const Size(740, 390), false, 1.0, false),
    (const Size(880, 1024), false, 2.0, false),
    (const Size(800, 600), true, 1.3, false),
    (const Size(1280, 900), true, 1.0, false),
  ]) {
    testWidgets(
      'graph and numeric actions fit $size scale=$scale keyboard=$keyboard',
      (tester) async {
        final container = await mount(
          tester,
          size: size,
          desktop: desktop,
          scale: scale,
          keyboard: keyboard,
        );
        expect(find.byKey(const ValueKey('eq-graph-plot')), findsOneWidget);
        final input = find.byKey(const ValueKey('eq-input-q'));
        await tester.scrollUntilVisible(
          input,
          100,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('eq-band-controls')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.ensureVisible(input);
        await tester.pumpAndSettle();
        await tester.tap(input);
        await tester.pumpAndSettle();
        expect(find.text('1.414'), findsOneWidget);
        expect(
          tester.getRect(find.byKey(const ValueKey('eq-number-done'))).bottom,
          lessThanOrEqualTo(size.height),
        );
        await tester.tap(find.byKey(const ValueKey('eq-number-done')));
        await tester.pumpAndSettle();
        final filter = container
            .read(equalizerProvider)
            .requireValue
            .configuration
            .filters
            .single;
        expect(filter.q, 1.4142135623730951);
        expect(filter.frequencyHz, 1234.56789);
        expect(tester.takeException(), isNull);
      },
      skip: !sqliteAvailable,
    );
  }

  testWidgets('numeric preview cancel, exact commit, invalid input and Undo', (
    tester,
  ) async {
    final container = await mount(tester);
    final controller = container.read(equalizerProvider.notifier);
    final original = container
        .read(equalizerProvider)
        .requireValue
        .configuration;
    await tester.tap(find.byKey(const ValueKey('eq-input-gain')));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('eq-graph-plot'))).height,
      greaterThanOrEqualTo(80),
      reason: 'The compact numeric preview must retain enough space to draw.',
    );
    await tester.enterText(find.byKey(const ValueKey('eq-edit-gain')), '-');
    await tester.tap(find.byKey(const ValueKey('eq-number-done')));
    await tester.pump();
    expect(find.byKey(const ValueKey('eq-edit-gain')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('eq-edit-gain')),
      '6.1234567',
    );
    await tester.pumpAndSettle();
    expect(
      container.read(equalizerProvider).requireValue.configuration,
      original,
    );
    await tester.tap(find.byKey(const ValueKey('eq-number-cancel')));
    await tester.pumpAndSettle();
    expect(
      container.read(equalizerProvider).requireValue.configuration,
      original,
    );
    await tester.tap(find.byKey(const ValueKey('eq-input-gain')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('eq-edit-gain')),
      '6.1234567',
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
      6.1234567,
    );
    await controller.undo();
    await tester.pumpAndSettle();
    expect(
      container.read(equalizerProvider).requireValue.configuration,
      original,
    );
  }, skip: !sqliteAvailable);

  testWidgets('exact preamp entry reveals output without moving bands', (
    tester,
  ) async {
    final container = await mount(tester);
    final before = container.read(equalizerProvider).requireValue.configuration;
    final screen = tester.state<EqualizerScreenState>(
      find.byType(EqualizerScreen),
    );
    screen.editNumber('preamp');
    await tester.pumpAndSettle();
    expect(find.textContaining('Output response:'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('eq-graph-plot'))).height,
      greaterThanOrEqualTo(80),
    );
    final preview = screen.typeNumber('-3.1234567');
    await tester.pumpAndSettle();
    await preview;
    await screen.finishNumber();
    await tester.pumpAndSettle();
    final after = container.read(equalizerProvider).requireValue.configuration;
    expect(after.preampDb, -3.1234567);
    expect(after.filters, before.filters);
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);

  testWidgets(
    'pointer drag has no grab jump, one Undo step and cancels correctly',
    (tester) async {
      final container = await mount(
        tester,
        size: const Size(1280, 900),
        desktop: true,
      );
      final original = container
          .read(equalizerProvider)
          .requireValue
          .configuration;
      final plot = tester.getRect(find.byKey(const ValueKey('eq-graph-plot')));
      final geometry = EqGraphGeometry.inside(plot.size);
      final handle = plot.topLeft + geometry.handle(original.filters.single);
      final gesture = await tester.startGesture(handle + const Offset(6, 0));
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -20));
      await gesture.up();
      await tester.pumpAndSettle();
      final changed = container
          .read(equalizerProvider)
          .requireValue
          .configuration;
      expect(
        changed.filters.single.frequencyHz,
        original.filters.single.frequencyHz,
      );
      expect(changed.filters.single.q, original.filters.single.q);
      expect(
        changed.filters.single.gainDb,
        greaterThan(original.filters.single.gainDb),
      );
      await container.read(equalizerProvider.notifier).undo();
      await tester.pumpAndSettle();
      expect(
        container.read(equalizerProvider).requireValue.configuration,
        original,
      );
      final cancel = await tester.startGesture(handle);
      await cancel.moveBy(const Offset(40, 0));
      await tester.pump();
      await cancel.cancel();
      await tester.pumpAndSettle();
      expect(
        container.read(equalizerProvider).requireValue.configuration,
        original,
      );
    },
    skip: !sqliteAvailable,
  );

  testWidgets('keyboard nudges and exact entry share the selected band', (
    tester,
  ) async {
    final container = await mount(
      tester,
      size: const Size(1280, 900),
      desktop: true,
      dark: true,
    );
    final before = container.read(equalizerProvider).requireValue.configuration;
    final plot = tester.getRect(find.byKey(const ValueKey('eq-graph-plot')));
    final geometry = EqGraphGeometry.inside(plot.size);
    await tester.tapAt(plot.topLeft + geometry.handle(before.filters.single));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      container
          .read(equalizerProvider)
          .requireValue
          .configuration
          .filters
          .single
          .gainDb,
      closeTo(before.filters.single.gainDb + .1, 1e-10),
    );
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);
  testWidgets(
    'overlapping disabled bands are selectable without enabling them',
    (tester) async {
      final container = await mount(
        tester,
        size: const Size(1280, 900),
        desktop: true,
      );
      await container
          .read(equalizerProvider.notifier)
          .setConfiguration(
            EqConfiguration(
              mode: EqMode.advanced,
              filters: const [
                EqFilter(frequencyHz: 1000),
                EqFilter(frequencyHz: 1001, enabled: false),
              ],
            ),
          );
      await tester.pumpAndSettle();
      final plot = tester.getRect(find.byKey(const ValueKey('eq-graph-plot')));
      final geometry = EqGraphGeometry.inside(plot.size);
      await tester.tapAt(
        plot.topLeft + geometry.handle(const EqFilter(frequencyHz: 1000)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsOneWidget);
      await tester.tap(find.text('Band 2 · 1001 Hz').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('eq-input-gain')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('eq-edit-gain')),
        '-3.987654',
      );
      await tester.tap(find.byKey(const ValueKey('eq-number-done')));
      await tester.pumpAndSettle();
      final second = container
          .read(equalizerProvider)
          .requireValue
          .configuration
          .filters[1];
      expect(second.enabled, isFalse);
      expect(second.gainDb, -3.987654);
    },
    skip: !sqliteAvailable,
  );

  testWidgets(
    'Edit in Advanced protects existing work by creating a separate preset',
    (tester) async {
      final container = await mount(tester);
      final controller = container.read(equalizerProvider.notifier);
      final advanced = container
          .read(equalizerProvider)
          .requireValue
          .configuration;
      await controller.changeMode(EqMode.simple);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('eq-input-frequency')),
            )
            .onPressed,
        isNull,
      );
      await tester.scrollUntilVisible(
        find.text('Edit in Advanced'),
        100,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('eq-band-controls')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit in Advanced'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create a new preset from this curve'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Current fixed curve');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      final state = container.read(equalizerProvider).requireValue;
      expect(state.selected!.name, 'Current fixed curve');
      expect(state.configuration.filters, hasLength(5));
      expect(state.configuration.mode, EqMode.advanced);
      expect(
        state.workspaces['builtin:flat']!.curves[EqMode.advanced],
        advanced,
      );
    },
    skip: !sqliteAvailable,
  );
}
