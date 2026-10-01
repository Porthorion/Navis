import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/domain/eq_workspace.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

class _Handler extends Mock implements NavisPlaybackHandler;

void main() {
  setUpAll(() => registerFallbackValue(EqConfiguration.flat()));
  test(
    'independent named drafts and mode variants survive provider restart',
    () async {
      final db = createTestDatabase();
      final container = ProviderContainer(
        overrides: withTestDatabase(
          db,
          overrides: [audioHandlerProvider.overrideWithValue(null)],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      await container.read(equalizerProvider.future);
      var controller = container.read(equalizerProvider.notifier);
      final bass = EqPreset.builtIns[1];
      final vocal = EqPreset.builtIns[2];
      await controller.selectPreset(bass);
      await controller.setConfiguration(
        container
            .read(equalizerProvider)
            .requireValue
            .configuration
            .copyWith(preampDb: -3.12735),
      );
      expect(
        container.read(equalizerProvider).requireValue.displayName('Custom'),
        'Bass boost*',
      );
      await controller.changeMode(EqMode.tenBand);
      await controller.setConfiguration(
        container
            .read(equalizerProvider)
            .requireValue
            .configuration
            .copyWith(preampDb: -6),
      );
      await controller.changeMode(EqMode.advanced);
      final converted = container
          .read(equalizerProvider)
          .requireValue
          .configuration;
      expect(converted.filters.first.q, 1.4142135623730951);
      await controller.selectPreset(vocal);
      await controller.setConfiguration(
        container
            .read(equalizerProvider)
            .requireValue
            .configuration
            .copyWith(preampDb: -9),
      );
      await controller.selectPreset(bass);
      expect(
        container.read(equalizerProvider).requireValue.configuration,
        converted,
      );
      await controller.changeMode(EqMode.simple);
      expect(
        container.read(equalizerProvider).requireValue.configuration.preampDb,
        -3.12735,
      );
      await controller.setEnabled(enabled: true);
      container.invalidate(equalizerProvider);
      var restored = await container.read(equalizerProvider.future);
      expect(restored.selectedPresetId, bass.id);
      expect(restored.configuration.preampDb, -3.12735);
      expect(restored.configuration.enabled, isTrue);
      controller = container.read(equalizerProvider.notifier);
      await controller.selectPreset(vocal);
      expect(
        container.read(equalizerProvider).requireValue.configuration.preampDb,
        -9,
      );
      await controller.discardChanges();
      restored = container.read(equalizerProvider).requireValue;
      expect(sameEqCurve(restored.configuration, vocal.configuration), isTrue);
      expect(restored.configuration.enabled, isTrue);
      expect(restored.hasDraft(bass.id), isTrue);
      expect(restored.hasDraft(vocal.id), isFalse);
    },
    skip: !sqliteAvailable,
  );

  test(
    'Save commits only the active mode and rename preserves other drafts',
    () async {
      final db = createTestDatabase();
      final container = ProviderContainer(
        overrides: withTestDatabase(
          db,
          overrides: [audioHandlerProvider.overrideWithValue(null)],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      await container.read(equalizerProvider.future);
      final controller = container.read(equalizerProvider.notifier);
      final preset = (await controller.saveAs('Headphones'))!;
      await controller.setConfiguration(
        container
            .read(equalizerProvider)
            .requireValue
            .configuration
            .copyWith(preampDb: -2),
      );
      await controller.changeMode(EqMode.tenBand);
      await controller.setConfiguration(
        container
            .read(equalizerProvider)
            .requireValue
            .configuration
            .copyWith(preampDb: -4),
      );
      await controller.updatePreset();
      var value = container.read(equalizerProvider).requireValue;
      expect(value.dirty, isFalse);
      expect(value.hasDraft(preset.id), isTrue);
      await controller.rename(preset, 'My headphones');
      await controller.changeMode(EqMode.simple);
      value = container.read(equalizerProvider).requireValue;
      expect(value.configuration.preampDb, -2);
      expect(value.displayName('Custom'), 'My headphones*');
      expect(await controller.deletePreset(value.selected!), isFalse);
      final replacement = await controller.preserveDraftAs(
        value.selected!,
        'Recovered',
      );
      expect(replacement, isNotNull);
      await controller.deletePreset(preset, discardDrafts: true);
      expect(
        container
            .read(equalizerProvider)
            .requireValue
            .workspaces[replacement!.id]!
            .curves
            .length,
        2,
      );
    },
    skip: !sqliteAvailable,
  );

  test('unawaited slider updates still form one gesture and switching retains both drafts', () async {
    final db = createTestDatabase();
    final container = ProviderContainer(
      overrides: withTestDatabase(
        db,
        overrides: [audioHandlerProvider.overrideWithValue(null)],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await container.read(equalizerProvider.future);
    final controller = container.read(equalizerProvider.notifier);
    final initial = container
        .read(equalizerProvider)
        .requireValue
        .configuration;
    controller.beginGesture();
    final edits = [
      for (final gain in [-1.0, -2.0, -3.0])
        controller.setConfiguration(initial.copyWith(preampDb: gain)),
    ];
    controller.endGesture();
    await Future.wait(edits);
    await controller.undo();
    expect(
      container.read(equalizerProvider).requireValue.configuration.preampDb,
      0,
    );
    expect(controller.canUndo, isFalse);
    final editA = controller.setConfiguration(initial.copyWith(preampDb: -4));
    final selectB = controller.selectPreset(EqPreset.builtIns[1]);
    final editB = controller.setConfiguration(
      container
          .read(equalizerProvider)
          .requireValue
          .configuration
          .copyWith(preampDb: -7),
    );
    await Future.wait([editA, selectB, editB]);
    final restored = await container.read(eqRepositoryProvider).load();
    expect(restored.selectedPresetId, EqPreset.builtIns[1].id);
    expect(restored.workspaces['builtin:flat']!.configuration.preampDb, -4);
    expect(restored.workspaces['builtin:bass']!.configuration.preampDb, -7);
  }, skip: !sqliteAvailable);

  test(
    'slider gesture is one Undo step with separate per-mode history',
    () async {
      final db = createTestDatabase();
      final container = ProviderContainer(
        overrides: withTestDatabase(
          db,
          overrides: [audioHandlerProvider.overrideWithValue(null)],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      await container.read(equalizerProvider.future);
      final controller = container.read(equalizerProvider.notifier);
      final initial = container
          .read(equalizerProvider)
          .requireValue
          .configuration;
      controller.beginGesture();
      await controller.setConfiguration(initial.copyWith(preampDb: -1));
      await controller.setConfiguration(initial.copyWith(preampDb: -2));
      await controller.setConfiguration(initial.copyWith(preampDb: -3));
      controller.endGesture();
      await controller.changeMode(EqMode.advanced);
      expect(controller.canUndo, isFalse);
      await controller.changeMode(EqMode.simple);
      await controller.undo();
      expect(
        container.read(equalizerProvider).requireValue.configuration.preampDb,
        0,
      );
      expect(controller.canUndo, isFalse);
      await controller.redo();
      expect(
        container.read(equalizerProvider).requireValue.configuration.preampDb,
        -3,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'unnamed legacy work remains selectable and survives switching',
    () async {
      final db = createTestDatabase();
      final curve = EqConfiguration.flat().copyWith(preampDb: -2.739);
      final container = ProviderContainer(
        overrides: withTestDatabase(
          db,
          overrides: [audioHandlerProvider.overrideWithValue(null)],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      await container
          .read(eqRepositoryProvider)
          .saveConfiguration(
            configuration: curve,
            selectedPresetId: null,
            originPresetId: null,
          );
      await container.read(equalizerProvider.future);
      final controller = container.read(equalizerProvider.notifier);
      await controller.selectPreset(EqPreset.builtIns.first);
      expect(
        container
            .read(equalizerProvider)
            .requireValue
            .hasDraft(eqCustomWorkspace),
        isTrue,
      );
      await controller.selectCustom();
      expect(
        container.read(equalizerProvider).requireValue.configuration,
        curve,
      );
      container.invalidate(equalizerProvider);
      expect(
        (await container.read(equalizerProvider.future)).configuration,
        curve,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'preview cancellation restores sound without persisting preview or Undo',
    () async {
      final db = createTestDatabase();
      final handler = _Handler();
      final applied = <EqConfiguration>[];
      when(() => handler.equalizerCapabilities)
          .thenReturn(EqCapabilities.available);
      when(() => handler.equalizerStateStream)
          .thenAnswer((_) => const Stream.empty());
      when(() => handler.equalizerState).thenAnswer(
        (_) => EqApplicationState(desired: applied.last, applied: applied.last),
      );
      when(handler.refreshEqualizerState).thenAnswer((_) async {});
      when(() => handler.setEqualizer(any())).thenAnswer((i) async {
        applied.add(i.positionalArguments.first as EqConfiguration);
      });
      final container = ProviderContainer(
        overrides: withTestDatabase(
          db,
          overrides: [audioHandlerProvider.overrideWithValue(handler)],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      await container.read(equalizerProvider.future);
      final controller = container.read(equalizerProvider.notifier);
      await controller.setEnabled(enabled: true);
      final before = container
          .read(equalizerProvider)
          .requireValue
          .configuration;
      final token = controller.beginPreview();
      await controller.preview(before.copyWith(preampDb: -8), token);
      expect(applied.last.preampDb, -8);
      expect(
        container.read(equalizerProvider).requireValue.configuration,
        before,
      );
      await controller.cancelPreview(token);
      expect(applied.last, before);
      expect(
        (await container.read(eqRepositoryProvider).load()).configuration,
        before,
      );
      expect(controller.canUndo, isFalse);
      expect(
        await controller.preview(before.copyWith(preampDb: -12), token),
        isFalse,
      );
    },
    skip: !sqliteAvailable,
  );
}
