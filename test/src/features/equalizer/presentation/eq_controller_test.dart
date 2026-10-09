import 'package:navis/src/features/equalizer/domain/eq_workspace.dart';

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/data/eq_repository.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

class _Handler extends Mock implements NavisPlaybackHandler;

class _Repository extends Mock implements EqRepository;

void main() {
  setUpAll(() => registerFallbackValue(EqConfiguration.flat()));
  test('storage failure remains visible and identical configuration retries persistence', () async {
    final database = createTestDatabase();
    final real = EqRepository(database.eqDao);
    final repository = _Repository();
    when(repository.load).thenAnswer((_) => real.load());
    var saves = 0;
    when(
      () => repository.saveConfiguration(
        configuration: any(named: 'configuration'),
        selectedPresetId: any(named: 'selectedPresetId'),
        originPresetId: any(named: 'originPresetId'),
        workspaces: any(named: 'workspaces'),
      ),
    ).thenAnswer((i) async {
      if (++saves == 1) throw StateError('storage unavailable');
      await real.saveConfiguration(
        configuration: i.namedArguments[#configuration] as EqConfiguration,
        selectedPresetId: i.namedArguments[#selectedPresetId] as String?,
        originPresetId: i.namedArguments[#originPresetId] as String?,
        workspaces: i.namedArguments[#workspaces] as Map<String, EqWorkspace>?,
      );
    });
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [
          audioHandlerProvider.overrideWithValue(null),
          eqRepositoryProvider.overrideWithValue(repository),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    final controller = container.read(equalizerProvider.notifier);
    await container.read(equalizerProvider.future);
    final curve = EqConfiguration.flat().copyWith(preampDb: -3.27);
    expect(await controller.setConfiguration(curve), isFalse);
    expect(container.read(equalizerProvider).requireValue.failure, isNotNull);
    expect((await real.load()).configuration, isNot(curve));
    expect(await controller.setConfiguration(curve), isTrue);
    expect((await real.load()).configuration, curve);
    expect(container.read(equalizerProvider).requireValue.failure, isNull);
    expect(saves, 2);
  }, skip: !sqliteAvailable);
  test(
    'presets are explicit, precise, mode preserving, and reset retains library',
    () async {
      final database = createTestDatabase();
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [audioHandlerProvider.overrideWithValue(null)],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      final controller = container.read(equalizerProvider.notifier);
      await container.read(equalizerProvider.future);
      final advanced = EqConfiguration(
        mode: EqMode.advanced,
        enabled: true,
        preampDb: -4.1273,
        filters: const [EqFilter(frequencyHz: 237.2, gainDb: 2.731, q: 1.038)],
      );
      expect(await controller.setConfiguration(advanced), isTrue);
      final saved = (await controller.saveAs('Headphones'))!;
      final edited = advanced.copyWith(preampDb: -3.27);
      await controller.setConfiguration(edited);
      var state = container.read(equalizerProvider).requireValue;
      expect(state.selectedPresetId, saved.id);
      expect(state.originPresetId, saved.id);
      expect(state.presets.single.configuration, advanced);
      expect(await controller.updatePreset(), isTrue);
      await controller.undo();
      expect(
        container.read(equalizerProvider).requireValue.configuration,
        advanced,
      );
      expect(
        container.read(equalizerProvider).requireValue.selectedPresetId,
        saved.id,
      );
      expect(
        container
            .read(equalizerProvider)
            .requireValue
            .presets
            .single
            .configuration,
        edited,
      );
      await controller.redo();
      expect(
        container.read(equalizerProvider).requireValue.selectedPresetId,
        saved.id,
      );
      await controller.setEnabled(enabled: false);
      await controller.selectPreset(state.presets.single);
      expect(
        container.read(equalizerProvider).requireValue.configuration.enabled,
        isFalse,
      );
      expect(
        container.read(equalizerProvider).requireValue.configuration.mode,
        EqMode.advanced,
      );
      expect(await controller.rename(saved, 'headphones'), isTrue);
      expect(await controller.saveAs('HEADPHONES'), isNull);
      expect(await controller.saveAs('Bass boost'), isNull);
      await controller.reset();
      state = container.read(equalizerProvider).requireValue;
      expect(state.configuration.enabled, isFalse);
      expect(
        sameEqCurve(
          state.configuration,
          EqConfiguration.flat(mode: state.configuration.mode),
        ),
        isTrue,
      );
      expect(state.presets.single.name, 'headphones');
      container.invalidate(equalizerProvider);
      final restored = await container.read(equalizerProvider.future);
      expect(restored.configuration, state.configuration);
      expect(restored.presets.single.id, saved.id);
    },
    skip: !sqliteAvailable,
  );

  test(
    'deleting an active preset preserves sound; Undo restores identity',
    () async {
      final database = createTestDatabase();
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [audioHandlerProvider.overrideWithValue(null)],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      final controller = container.read(equalizerProvider.notifier);
      await container.read(equalizerProvider.future);
      await controller.setConfiguration(
        EqConfiguration.flat(mode: EqMode.tenBand).copyWith(enabled: true),
      );
      final saved = (await controller.saveAs('Car'))!;
      final sound = container
          .read(equalizerProvider)
          .requireValue
          .configuration;
      expect(await controller.deletePreset(saved), isTrue);
      expect(
        container.read(equalizerProvider).requireValue.configuration,
        sound,
      );
      expect(
        container.read(equalizerProvider).requireValue.selectedPresetId,
        isNull,
      );
      expect(await controller.restorePreset(saved), isTrue);
      expect(
        container.read(equalizerProvider).requireValue.presets.single.id,
        saved.id,
      );
      await controller.setConfiguration(sound.copyWith(preampDb: -4));
      await controller.undo();
      expect(
        container.read(equalizerProvider).requireValue.configuration,
        sound,
      );
      await controller.redo();
      expect(
        container.read(equalizerProvider).requireValue.configuration.preampDb,
        -4,
      );
    },
    skip: !sqliteAvailable,
  );

  test('rapid edits skip stale callbacks and rejected audio retains the saved draft', () async {
    final database = createTestDatabase();
    final handler = _Handler();
    final applied = <EqConfiguration>[];
    when(() => handler.equalizerCapabilities)
        .thenReturn(EqCapabilities.available);
    when(() => handler.equalizerStateStream)
        .thenAnswer((_) => const Stream.empty());
    when(() => handler.equalizerState).thenAnswer(
      (_) => EqApplicationState(
        desired: applied.lastOrNull ?? EqConfiguration.flat(),
        applied: applied.lastOrNull ?? EqConfiguration.flat(),
      ),
    );
    when(handler.refreshEqualizerState).thenAnswer((_) async {});
    when(() => handler.setEqualizer(any())).thenAnswer((i) async {
      applied.add(i.positionalArguments.first as EqConfiguration);
    });
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [audioHandlerProvider.overrideWithValue(handler)],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    final controller = container.read(equalizerProvider.notifier);
    await container.read(equalizerProvider.future);
    await controller.setConfiguration(
      EqConfiguration.flat().copyWith(preampDb: -1),
    );
    final gate = Completer<void>();
    when(() => handler.setEqualizer(any())).thenAnswer((i) async {
      final configuration = i.positionalArguments.first as EqConfiguration;
      if (configuration.preampDb == -2) await gate.future;
      if (configuration.preampDb == 2) throw StateError('rejected');
      applied.add(configuration);
    });
    final first = controller.setConfiguration(
      EqConfiguration.flat().copyWith(preampDb: -2),
    );
    await Future<void>.delayed(Duration.zero);
    final superseded = controller.setConfiguration(
      EqConfiguration.flat().copyWith(preampDb: -3),
    );
    final latest = controller.setConfiguration(
      EqConfiguration.flat().copyWith(preampDb: -4),
    );
    gate.complete();
    await Future.wait([first, superseded, latest]);
    expect(applied.last.preampDb, -4);
    expect(applied.any((c) => c.preampDb == -3), isFalse);
    expect(
      (await container.read(eqRepositoryProvider).load())
          .configuration
          .preampDb,
      -4,
    );
    expect(
      await controller.setConfiguration(
        EqConfiguration.flat().copyWith(preampDb: 2),
      ),
      isFalse,
    );
    expect(
      container.read(equalizerProvider).requireValue.configuration.preampDb,
      2,
    );
    expect(applied.last.preampDb, -4);
    expect(
      (await container.read(eqRepositoryProvider).load())
          .configuration
          .preampDb,
      2,
    );
    expect(container.read(equalizerProvider).requireValue.failure, isNotNull);
  }, skip: !sqliteAvailable);
}
