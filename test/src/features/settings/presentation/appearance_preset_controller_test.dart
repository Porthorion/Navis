import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common/preset_names.dart';
import 'package:navis/src/features/settings/domain/appearance_presets.dart';
import 'package:navis/src/features/settings/presentation/appearance_preset_controller.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/color_adjustment.dart';

import '../../../../helpers/test_database.dart';

class _MockSettingsRepository extends Mock implements SettingsRepository;

void main() {
  test('tuning save select update rename delete and value matching', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final container = ProviderContainer(overrides: withTestDatabase(database));
    addTearDown(container.dispose);
    container.listen(colorTuningControllerProvider, (_, _) {});
    container.listen(appearanceLooksControllerProvider, (_, _) {});
    final controller = container.read(colorTuningControllerProvider.notifier);
    await container.read(appSettingsProvider.future);
    expect(
      container.read(colorTuningControllerProvider).selectedPresetId,
      'default',
    );
    const first = ColorTuning(vividness: 1, lightDepth: 2, darkDepth: -3);
    controller.preview(first);
    expect(container.read(effectiveColorTuningProvider), first);
    expect(
      container.read(colorTuningControllerProvider).selectedPresetId,
      isNull,
    );
    final saved = await controller.saveAsNew('  Warm  ');
    expect(saved.failure, isNull);
    final id = saved.value!.id;
    expect(saved.value!.name, 'Warm');
    expect(saved.value!.tuning, first);
    expect(container.read(colorTuningControllerProvider).selectedPresetId, id);
    expect(
      (await controller.saveAsNew('warm')).failure,
      PresetFailure.duplicateName,
    );
    expect(
      (await controller.saveAsNew('DEFAULT')).failure,
      PresetFailure.reservedName,
    );
    expect((await controller.saveAsNew(' ')).failure, PresetFailure.emptyName);
    expect(await controller.select('missing'), PresetFailure.notFound);
    expect(await controller.update('default'), PresetFailure.notFound);
    expect(await controller.rename(id, 'Default'), PresetFailure.reservedName);
    expect(await controller.select('default'), isNull);
    expect(
      container.read(colorTuningControllerProvider).selectedPresetId,
      'default',
    );
    expect(await controller.select(id), isNull);
    expect(container.read(colorTuningControllerProvider).tuning, first);
    const second = ColorTuning(vividness: 3, lightDepth: -2, darkDepth: 4);
    expect(await controller.commit(second), isNull);
    expect(
      container.read(colorTuningControllerProvider).selectedPresetId,
      isNull,
    );
    expect(await controller.update(id), isNull);
    expect(
      container.read(colorTuningControllerProvider).presets.single.tuning,
      second,
    );
    expect(await controller.rename(id, '  Evening  '), isNull);
    expect(
      container.read(colorTuningControllerProvider).presets.single.name,
      'Evening',
    );
    expect(await controller.commit(ColorTuning.none), isNull);
    expect(await controller.commit(second), isNull);
    expect(container.read(colorTuningControllerProvider).selectedPresetId, id);
    expect(await controller.delete(id), isNull);
    expect(container.read(colorTuningControllerProvider).tuning, second);
    expect(
      container.read(colorTuningControllerProvider).selectedPresetId,
      isNull,
    );
    expect(await controller.delete(id), PresetFailure.notFound);
    final settings = await container
        .read(settingsRepositoryProvider)
        .getSettings();
    expect(settings.colorTuningPresets, isEmpty);
    expect(settings.colorTuning, second);
    expect(settings.selectedColorTuningPresetId, isNull);
  }, skip: !sqliteAvailable);

  test(
    'failed commit clears preview and the next command can succeed',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final repository = SettingsRepository(database.appSettingsDao);
      final mock = _MockSettingsRepository();
      var fail = true;
      when(mock.watchSettings).thenAnswer((_) => repository.watchSettings());
      when(mock.getSettings).thenAnswer((_) async {
        if (fail) throw StateError('Test write failure');
        return await repository.getSettings();
      });
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [settingsRepositoryProvider.overrideWithValue(mock)],
        ),
      );
      addTearDown(container.dispose);
      container.listen(colorTuningControllerProvider, (_, _) {});
      final controller = container.read(colorTuningControllerProvider.notifier);
      await container.read(appSettingsProvider.future);
      const tuning = ColorTuning(lightDepth: -2, darkDepth: 4);
      expect(await controller.commit(tuning), PresetFailure.persistence);
      expect(container.read(colorTuningPreviewProvider), isNull);
      expect(
        container.read(colorTuningControllerProvider).tuning,
        ColorTuning.none,
      );
      fail = false;
      expect(await controller.commit(tuning), isNull);
      expect(container.read(colorTuningControllerProvider).tuning, tuning);
      expect(container.read(colorTuningPreviewProvider), isNull);
    },
    skip: !sqliteAvailable,
  );

  test(
    'queued commits and library operations preserve both new presets',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final container = ProviderContainer(
        overrides: withTestDatabase(database),
      );
      addTearDown(container.dispose);
      container.listen(colorTuningControllerProvider, (_, _) {});
      container.listen(appearanceLooksControllerProvider, (_, _) {});
      final controller = container.read(colorTuningControllerProvider.notifier);
      final results = await Future.wait([
        controller.saveAsNew('One'),
        controller.saveAsNew('Two'),
      ]);
      expect(results.every((r) => r.failure == null), isTrue);
      expect(
        (await container.read(settingsRepositoryProvider).getSettings())
            .colorTuningPresets,
        hasLength(2),
      );
      const one = ColorTuning(lightDepth: 1);
      const two = ColorTuning(darkDepth: 2);
      expect(
        await Future.wait([controller.commit(one), controller.commit(two)]),
        [null, null],
      );
      expect(
        (await container.read(settingsRepositoryProvider).getSettings())
            .colorTuning,
        two,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'tuning and Looks state follows external targeted settings writes',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final container = ProviderContainer(
        overrides: withTestDatabase(database),
      );
      addTearDown(container.dispose);
      container.listen(colorTuningControllerProvider, (_, _) {});
      container.listen(appearanceLooksControllerProvider, (_, _) {});
      final tuningStates = <ColorTuningState>[];
      final looksStates = <AppearanceLooksState>[];
      container.listen(
        colorTuningControllerProvider,
        (_, s) => tuningStates.add(s),
      );
      container.listen(
        appearanceLooksControllerProvider,
        (_, s) => looksStates.add(s),
      );
      await container.read(appSettingsProvider.future);
      final look =
          (await container
                  .read(appearanceLooksControllerProvider.notifier)
                  .saveAsNew('Original'))
              .value!;
      await database.appSettingsDao.updateColorTuning(
        const ColorTuning(darkDepth: 4),
      );
      await container
          .read(settingsRepositoryProvider)
          .watchSettings()
          .firstWhere((s) => s.surfaceDepthDark == 4);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(colorTuningControllerProvider).tuning.darkDepth, 4);
      expect(
        container.read(appearanceLooksControllerProvider).selectedLookId,
        isNull,
      );
      expect(tuningStates, isNotEmpty);
      expect(looksStates, isNotEmpty);
      expect(
        await container
            .read(appearanceLooksControllerProvider.notifier)
            .apply(look.id),
        isNull,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'Looks capture update apply rename delete and match first snapshot',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final container = ProviderContainer(
        overrides: withTestDatabase(database),
      );
      addTearDown(container.dispose);
      container.listen(colorTuningControllerProvider, (_, _) {});
      container.listen(appearanceLooksControllerProvider, (_, _) {});
      final controller = container.read(
        appearanceLooksControllerProvider.notifier,
      );
      final saved = await controller.saveAsNew('  Original  ');
      expect(saved.failure, isNull);
      final id = saved.value!.id;
      expect(saved.value!.version, 1);
      expect(saved.value!.snapshot.tuningPresetId, 'default');
      expect(
        container.read(appearanceLooksControllerProvider).selectedLookId,
        id,
      );
      final duplicateValues = (await controller.saveAsNew('Same values'))
          .value!;
      expect(
        container.read(appearanceLooksControllerProvider).selectedLookId,
        id,
      );
      expect(
        (await controller.saveAsNew('ORIGINAL')).failure,
        PresetFailure.duplicateName,
      );
      expect(
        (await controller.saveAsNew('Default')).failure,
        PresetFailure.reservedName,
      );
      expect(
        (await controller.saveAsNew(' ')).failure,
        PresetFailure.emptyName,
      );
      expect(
        await controller.rename(id, 'Same values'),
        PresetFailure.duplicateName,
      );
      await database.appSettingsDao.updateThemeMode('light');
      expect(await controller.update(id), isNull);
      expect(
        container
            .read(appearanceLooksControllerProvider)
            .looks
            .first
            .snapshot
            .themeMode,
        'light',
      );
      expect(await controller.rename(id, ' Sunny '), isNull);
      expect(
        container.read(appearanceLooksControllerProvider).looks.first.name,
        'Sunny',
      );
      await database.appSettingsDao.updateThemeMode('oled');
      expect(await controller.apply(id), isNull);
      expect(
        (await container.read(settingsRepositoryProvider).getSettings())
            .themeMode,
        'light',
      );
      expect(
        container.read(appearanceLooksControllerProvider).selectedLookId,
        id,
      );
      expect(await controller.apply(duplicateValues.id), isNull);
      expect(
        (await container.read(settingsRepositoryProvider).getSettings())
            .themeMode,
        'dark',
      );
      expect(await controller.delete(duplicateValues.id), isNull);
      expect(
        container.read(appearanceLooksControllerProvider).selectedLookId,
        isNull,
      );
      expect(await controller.delete(id), isNull);
      expect(container.read(appearanceLooksControllerProvider).looks, isEmpty);
      expect(await controller.apply(id), PresetFailure.notFound);
      expect(await controller.update(id), PresetFailure.notFound);
      expect(await controller.rename(id, 'Gone'), PresetFailure.notFound);
      expect(await controller.delete(id), PresetFailure.notFound);
    },
    skip: !sqliteAvailable,
  );

  test('Looks capture includes selected tuning preset metadata', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final container = ProviderContainer(overrides: withTestDatabase(database));
    addTearDown(container.dispose);
    container.listen(colorTuningControllerProvider, (_, _) {});
    container.listen(appearanceLooksControllerProvider, (_, _) {});
    final tuning = container.read(colorTuningControllerProvider.notifier);
    await tuning.commit(
      const ColorTuning(vividness: 2, lightDepth: -3, darkDepth: 4),
    );
    final preset = (await tuning.saveAsNew('Warm')).value!;
    final look =
        (await container
                .read(appearanceLooksControllerProvider.notifier)
                .saveAsNew('My look'))
            .value!;
    expect(look.snapshot.tuningPresetId, preset.id);
    expect(look.snapshot.surfaceDepthLight, -3);
    expect(look.snapshot.surfaceDepthDark, 4);
    expect(matchingColorTuningPresetId(ColorTuning.none, [preset]), 'default');
    const changed = ColorTuning(vividness: -1, lightDepth: 4, darkDepth: -2);
    await tuning.commit(changed);
    await tuning.update(preset.id);
    final looks = container.read(appearanceLooksControllerProvider.notifier);
    expect(await looks.apply(look.id), isNull);
    expect(container.read(colorTuningControllerProvider).tuning, changed);
    expect(
      container.read(colorTuningControllerProvider).selectedPresetId,
      preset.id,
    );
    expect(
      container.read(appearanceLooksControllerProvider).selectedLookId,
      isNull,
    );
    await tuning.delete(preset.id);
    expect(await looks.apply(look.id), isNull);
    expect(
      container.read(colorTuningControllerProvider).tuning,
      const ColorTuning(vividness: 2, lightDepth: -3, darkDepth: 4),
    );
    expect(
      container.read(colorTuningControllerProvider).selectedPresetId,
      isNull,
    );
    expect(
      container.read(appearanceLooksControllerProvider).selectedLookId,
      look.id,
    );
  }, skip: !sqliteAvailable);
}
