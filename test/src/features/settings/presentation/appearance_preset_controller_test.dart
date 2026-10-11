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
  test('tuning previews, clears and commits the three values', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final container = ProviderContainer(overrides: withTestDatabase(database));
    addTearDown(container.dispose);
    container.listen(colorTuningControllerProvider, (_, _) {});
    await container.read(appSettingsProvider.future);
    final controller = container.read(colorTuningControllerProvider.notifier);
    const tuning = ColorTuning(vividness: 1, lightDepth: 2, darkDepth: -3);
    controller.preview(tuning);
    expect(container.read(effectiveColorTuningProvider), tuning);
    expect(
      (await container.read(settingsRepositoryProvider).getSettings())
          .colorTuning,
      ColorTuning.none,
    );
    controller.clearPreview();
    expect(container.read(effectiveColorTuningProvider), ColorTuning.none);
    expect(await controller.commit(tuning), isNull);
    expect(container.read(colorTuningControllerProvider).tuning, tuning);
    expect(container.read(colorTuningPreviewProvider), isNull);
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

  test('queued tuning commits preserve the last requested values', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final container = ProviderContainer(overrides: withTestDatabase(database));
    addTearDown(container.dispose);
    container.listen(colorTuningControllerProvider, (_, _) {});
    container.listen(appearanceLooksControllerProvider, (_, _) {});
    final controller = container.read(colorTuningControllerProvider.notifier);
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
  }, skip: !sqliteAvailable);

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
        isA<AppearanceSnapshot>(),
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'Looks capture update apply rename delete and keep the chosen Look',
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
      expect(saved.value!.snapshot.colorVividness, 0);
      expect(
        container.read(appearanceLooksControllerProvider).selectedLookId,
        id,
      );
      final duplicateValues = (await controller.saveAsNew('Same values'))
          .value!;
      // A new save is the chosen Look, even when its values match another.
      expect(
        container.read(appearanceLooksControllerProvider).selectedLookId,
        duplicateValues.id,
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
      expect(await controller.apply(id), isA<AppearanceSnapshot>());
      expect(
        (await container.read(settingsRepositoryProvider).getSettings())
            .themeMode,
        'light',
      );
      expect(
        container.read(appearanceLooksControllerProvider).selectedLookId,
        id,
      );
      expect(
        await controller.apply(duplicateValues.id),
        isA<AppearanceSnapshot>(),
      );
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
      expect(await controller.apply(id), isNull);
      expect(await controller.update(id), PresetFailure.notFound);
      expect(await controller.rename(id, 'Gone'), PresetFailure.notFound);
      expect(await controller.delete(id), PresetFailure.notFound);
    },
    skip: !sqliteAvailable,
  );

  test('Looks capture tuning values directly', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final container = ProviderContainer(overrides: withTestDatabase(database));
    addTearDown(container.dispose);
    container.listen(colorTuningControllerProvider, (_, _) {});
    container.listen(appearanceLooksControllerProvider, (_, _) {});
    const saved = ColorTuning(vividness: 2, lightDepth: -3, darkDepth: 4);
    final tuning = container.read(colorTuningControllerProvider.notifier);
    await tuning.commit(saved);
    final looks = container.read(appearanceLooksControllerProvider.notifier);
    final look = (await looks.saveAsNew('My look')).value!;
    expect(look.snapshot.colorVividness, 2);
    expect(look.snapshot.surfaceDepthLight, -3);
    expect(look.snapshot.surfaceDepthDark, 4);
    await tuning.commit(
      const ColorTuning(vividness: -1, lightDepth: 4, darkDepth: -2),
    );
    expect(await looks.apply(look.id), isA<AppearanceSnapshot>());
    expect(container.read(colorTuningControllerProvider).tuning, saved);
    expect(
      container.read(appearanceLooksControllerProvider).selectedLookId,
      look.id,
    );
  }, skip: !sqliteAvailable);

  for (final matchedLook in [false, true]) {
    test(
      'apply and restore round-trip every snapshot field, matched Look=$matchedLook',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final container = ProviderContainer(
          overrides: withTestDatabase(database),
        );
        addTearDown(container.dispose);
        container.listen(appearanceLooksControllerProvider, (_, _) {});
        final controller = container.read(
          appearanceLooksControllerProvider.notifier,
        );
        final repository = container.read(settingsRepositoryProvider);
        final target = (await controller.saveAsNew('Target')).value!;
        // Exercise all appearance fields, including both explicit nulls.
        final before = AppearanceSnapshot.fromJson(const {
          'themeMode': 'system',
          'oledForAuto': true,
          'colorStyle': 'immersive',
          'colorSchemeSeed': null,
          'dynamicAlbumColorEnabled': true,
          'nightScheduleEnabled': true,
          'nightScheduleStartMinutes': 123,
          'nightScheduleEndMinutes': 456,
          'albumArtShade': true,
          'albumArtColoredShade': true,
          'colorVividness': 4,
          'surfaceDepthLight': -2,
          'surfaceDepthDark': 3,
          'surfaceTintLight': 5,
          'surfaceTintDark': 3,
          'controlColor': 'white',
          'flatSurfaces': true,
          'flatAreas': 2,
          'cornerStyle': 'square',
          'coverArtShape': 'rounded',
          'nowPlayingArtShape': 'circle',
          'artistCardShape': 'square',
          'gridArtworkSize': 'large',
          'albumGridDensity': null,
          'density': 'compact',
          'artistViewMode': 'list',
          'nowPlayingBackground': 'artwork',
        });
        expect(before.toJson(), hasLength(27));
        await database.appSettingsDao.applyAppearanceSnapshot(before);
        String? previousLookId;
        if (matchedLook) {
          previousLookId = (await controller.saveAsNew('Previous')).value!.id;
        }
        await database.appSettingsDao.applyAppearanceSnapshot(target.snapshot);
        await database.appSettingsDao.applyAppearanceSnapshot(
          const AppearanceSnapshot(colorSchemeSeed: 1, albumGridDensity: 6),
        );
        await controller.update(target.id);
        final updatedTarget = AppearanceSnapshot.capture(
          await repository.getSettings(),
        );
        await database.appSettingsDao.applyAppearanceSnapshot(before);
        final previous = await controller.apply(target.id);
        expect(previous, before);
        expect(
          AppearanceSnapshot.capture(await repository.getSettings()),
          updatedTarget,
        );
        expect(await controller.restore(previous!), isNull);
        final restored = await repository.getSettings();
        expect(AppearanceSnapshot.capture(restored).toJson(), before.toJson());
        expect(restored.themeMode, 'system');
        expect(restored.colorSchemeSeed, isNull);
        expect(restored.albumGridDensity, isNull);
        expect(
          restored.colorTuning,
          const ColorTuning(
            vividness: 4,
            lightDepth: -2,
            darkDepth: 3,
            lightTint: 5,
            darkTint: 3,
            controls: NavisControlColor.white,
          ),
        );
        expect(
          container.read(appearanceLooksControllerProvider).selectedLookId,
          previousLookId,
        );
        expect(restored.selectedAppearanceLookId, previousLookId);
      },
      skip: !sqliteAvailable,
    );
  }

  test(
    'failure after snapshot write rolls back the appearance transaction',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final repository = SettingsRepository(database.appSettingsDao);
      final seed = ProviderContainer(overrides: withTestDatabase(database));
      addTearDown(seed.dispose);
      final look =
          (await seed
                  .read(appearanceLooksControllerProvider.notifier)
                  .saveAsNew('Original'))
              .value!;
      await database.appSettingsDao.updateThemeMode('light');
      final before = AppearanceSnapshot.capture(await repository.getSettings());
      final mock = _MockSettingsRepository();
      when(mock.watchSettings).thenAnswer((_) => repository.watchSettings());
      var reads = 0;
      when(mock.getSettings).thenAnswer((_) async {
        if (++reads == 3) {
          throw StateError('Post-write read failure');
        }
        return await repository.getSettings();
      });
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [settingsRepositoryProvider.overrideWithValue(mock)],
        ),
      );
      addTearDown(container.dispose);
      final controller = container.read(
        appearanceLooksControllerProvider.notifier,
      );
      expect(await controller.apply(look.id), isNull);
      expect(
        AppearanceSnapshot.capture(await repository.getSettings()),
        before,
      );
      // Restore enters the transaction without the initial Look lookup.
      reads = 1;
      expect(
        await controller.restore(look.snapshot),
        PresetFailure.persistence,
      );
      expect(
        AppearanceSnapshot.capture(await repository.getSettings()),
        before,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'failed apply and restore report failure without changing appearance',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final repository = SettingsRepository(database.appSettingsDao);
      final mock = _MockSettingsRepository();
      when(mock.watchSettings).thenAnswer((_) => repository.watchSettings());
      when(mock.getSettings).thenThrow(StateError('Unavailable settings'));
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [settingsRepositoryProvider.overrideWithValue(mock)],
        ),
      );
      addTearDown(container.dispose);
      final controller = container.read(
        appearanceLooksControllerProvider.notifier,
      );
      expect(await controller.apply('missing'), isNull);
      expect(
        await controller.restore(const AppearanceSnapshot(themeMode: 'light')),
        PresetFailure.persistence,
      );
      expect((await repository.getSettings()).themeMode, 'dark');
    },
    skip: !sqliteAvailable,
  );
}
