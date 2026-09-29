import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/equalizer/data/eq_repository.dart';
import 'package:navis/src/features/equalizer/data/eq_import_parser.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/domain/eq_workspace.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

class _Repository extends Mock implements EqRepository {}

class _Handler extends Mock implements NavisPlaybackHandler {}

void main() {
  setUpAll(() => registerFallbackValue(EqConfiguration.flat()));

  Future<(ProviderContainer, EqRepository, List<EqConfiguration>)> fixture({
    bool fail = false,
    Completer<void>? gate,
  }) async {
    final db = createTestDatabase();
    final real = EqRepository(db.eqDao);
    final repository = _Repository();
    final writes = <EqConfiguration>[];
    when(repository.load).thenAnswer((_) => real.load());
    when(
      () => repository.saveConfiguration(
        configuration: any(named: 'configuration'),
        selectedPresetId: any(named: 'selectedPresetId'),
        originPresetId: any(named: 'originPresetId'),
        workspaces: any(named: 'workspaces'),
      ),
    ).thenAnswer((invocation) async {
      final configuration =
          invocation.namedArguments[#configuration] as EqConfiguration;
      writes.add(configuration);
      if (gate != null && writes.length == 1) await gate.future;
      if (fail) throw StateError('write failed');
      await real.saveConfiguration(
        configuration: configuration,
        selectedPresetId:
            invocation.namedArguments[#selectedPresetId] as String?,
        originPresetId: invocation.namedArguments[#originPresetId] as String?,
        workspaces:
            invocation.namedArguments[#workspaces] as Map<String, EqWorkspace>?,
      );
    });
    final container = ProviderContainer(
      overrides: withTestDatabase(
        db,
        overrides: [
          audioHandlerProvider.overrideWithValue(null),
          eqRepositoryProvider.overrideWithValue(repository),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await container.read(equalizerProvider.future);
    return (container, real, writes);
  }

  test(
    'a thousand pointer updates commit one write and one Undo step',
    () async {
      final (container, real, writes) = await fixture();
      final controller = container.read(equalizerProvider.notifier);
      final original = container
          .read(equalizerProvider)
          .requireValue
          .configuration;
      final token = controller.beginGraphEdit();
      for (var i = 0; i < 1000; i++) {
        controller.updateGraphEdit(
          token,
          original.copyWith(preampDb: -i / 100),
        );
      }
      expect(writes, isEmpty);
      await controller.endGraphEdit(token);
      expect(writes, hasLength(1));
      expect((await real.load()).configuration.preampDb, -9.99);
      await controller.undo();
      expect(
        container.read(equalizerProvider).requireValue.configuration,
        original,
      );
      expect(controller.canUndo, isFalse);
    },
    skip: !sqliteAvailable,
  );

  test(
    'checkpoint recovers after restart and canceled drag restores it',
    () async {
      final (container, real, writes) = await fixture();
      final controller = container.read(equalizerProvider.notifier);
      final original = container
          .read(equalizerProvider)
          .requireValue
          .configuration;
      final token = controller.beginGraphEdit();
      final updated = original.copyWith(preampDb: -3.123456);
      controller.updateGraphEdit(token, updated);
      await Future<void>.delayed(const Duration(milliseconds: 310));
      expect(writes, hasLength(1));
      expect((await real.load()).configuration, updated);
      expect(
        container.read(equalizerProvider).requireValue.draftPersisted,
        isTrue,
      );
      await controller.endGraphEdit(token, cancel: true);
      expect((await real.load()).configuration, original);
      expect(controller.canUndo, isFalse);
      container.invalidate(equalizerProvider);
      expect(
        (await container.read(equalizerProvider.future)).configuration,
        original,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'slow checkpoint and rapid switching never write into another workspace',
    () async {
      final gate = Completer<void>();
      final (container, real, writes) = await fixture(gate: gate);
      final controller = container.read(equalizerProvider.notifier);
      final original = container
          .read(equalizerProvider)
          .requireValue
          .configuration;
      final token = controller.beginGraphEdit();
      controller.updateGraphEdit(token, original.copyWith(preampDb: -4.56789));
      await Future<void>.delayed(const Duration(milliseconds: 280));
      expect(writes, hasLength(1));
      controller.updateGraphEdit(
        token,
        original.copyWith(preampDb: -8.1234567),
      );
      final switchPreset = controller.selectPreset(EqPreset.builtIns[1]);
      expect(controller.graphEditIsCurrent(token), isFalse);
      controller.updateGraphEdit(token, original.copyWith(preampDb: -20));
      gate.complete();
      await switchPreset;
      final saved = await real.load();
      expect(saved.selectedPresetId, 'builtin:bass');
      expect(
        saved.workspaces['builtin:flat']!.configuration.preampDb,
        -8.1234567,
      );
      expect(saved.configuration.preampDb, 0);
      await controller.selectPreset(EqPreset.builtIns.first);
      await controller.undo();
      expect(
        container.read(equalizerProvider).requireValue.configuration,
        original,
      );
    },
    skip: !sqliteAvailable,
  );

  test('failed drag persistence retains recoverable memory and does not claim saved', () async {
    final (container, _, _) = await fixture(fail: true);
    final controller = container.read(equalizerProvider.notifier);
    final original = container
        .read(equalizerProvider)
        .requireValue
        .configuration;
    final token = controller.beginGraphEdit();
    controller.updateGraphEdit(token, original.copyWith(preampDb: -7.987654));
    expect(await controller.endGraphEdit(token), isFalse);
    final value = container.read(equalizerProvider).requireValue;
    expect(value.configuration.preampDb, -7.987654);
    expect(value.draftPersisted, isFalse);
    expect(value.failure, contains('could not be saved'));
  }, skip: !sqliteAvailable);

  test(
    'slow native preview coalesces pending commands and latest value wins',
    () async {
      final db = createTestDatabase();
      final handler = _Handler();
      final native = <EqConfiguration>[];
      when(() => handler.equalizerCapabilities)
          .thenReturn(EqCapabilities.available);
      when(() => handler.equalizerStateStream)
          .thenAnswer((_) => const Stream.empty());
      when(() => handler.equalizerState).thenAnswer(
        (_) => EqApplicationState(desired: native.last, applied: native.last),
      );
      when(handler.refreshEqualizerState).thenAnswer((_) async {});
      final gate = Completer<void>();
      var slow = false;
      when(() => handler.setEqualizer(any())).thenAnswer((i) async {
        if (slow) await gate.future;
        native.add(i.positionalArguments.first as EqConfiguration);
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
      final original = container
          .read(equalizerProvider)
          .requireValue
          .configuration;
      final token = controller.beginPreview();
      slow = true;
      final first = controller.preview(original.copyWith(preampDb: -1), token);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final pending = <Future<bool>>[];
      for (var i = 0; i < 1000; i++) {
        pending.add(
          controller.preview(original.copyWith(preampDb: -i / 100), token),
        );
      }
      final before = native.length;
      gate.complete();
      await first;
      await Future.wait(pending);
      expect(native.length - before, 2);
      expect(native.last.preampDb, -9.99);
      await controller.cancelPreview(token);
      expect(native.last, original);
    },
    skip: !sqliteAvailable,
  );
  test(
    'AutoEQ graph edits and export retain untouched precision and provenance',
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
      for (final fixed in [false, true]) {
        final original = EqImportParser().parse(
          'Preamp: -6.123456789 dB\nFilter 1: OFF PK Fc 1234.56789 Hz Gain -3.123456789 dB Q 1.4142135623730951\nFilter 2: ON PK Fc 5678.123456 Hz Gain 1.987654321 dB Q 0.7123456789',
          id: 'preview',
          name: 'Precision $fixed',
          fixedBand: fixed,
          sourceUrl: 'https://example.invalid/profile',
          revision: 'fixture-revision',
          measurementSource: 'Fixture',
        );
        await controller.saveAs(original.name, imported: original);
        final start = container
            .read(equalizerProvider)
            .requireValue
            .configuration;
        final token = controller.beginGraphEdit();
        final filters = [...start.filters];
        filters[0] = filters[0].copyWith(gainDb: -4.23456789);
        controller.updateGraphEdit(token, start.copyWith(filters: filters));
        await controller.endGraphEdit(token);
        await controller.updatePreset();
        final saved = container.read(equalizerProvider).requireValue.selected!;
        final exported = EqImportParser().parse(
          jsonEncode(saved.toJson()),
          id: 'roundtrip',
          name: 'Unused',
        );
        expect(exported.configuration, saved.configuration);
        expect(
          exported.configuration.mode,
          fixed ? EqMode.importedFixed : EqMode.advanced,
        );
        expect(
          exported.configuration.preampDb,
          original.configuration.preampDb,
        );
        expect(
          exported.configuration.filters[0].q,
          original.configuration.filters[0].q,
        );
        expect(
          exported.configuration.filters[0].frequencyHz,
          original.configuration.filters[0].frequencyHz,
        );
        expect(exported.configuration.filters[0].enabled, isFalse);
        expect(
          exported.configuration.filters[1],
          original.configuration.filters[1],
        );
        expect(exported.source!.toJson(), original.source!.toJson());
      }
    },
    skip: !sqliteAvailable,
  );
}
