import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/equalizer/data/eq_repository.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';

import '../../../../helpers/test_database.dart';

void main() {
  test(
    'repeated draft saves keep one row and do not acknowledge reset notice',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final repository = EqRepository(database.eqDao);
      await database.customStatement(
        'INSERT INTO eq_state (id,legacy_reset_notice) VALUES (1,1)',
      );
      for (var i = 0; i < 8; i++) {
        await repository.saveConfiguration(
          configuration: EqConfiguration.flat().copyWith(
            preampDb: -i.toDouble(),
          ),
          selectedPresetId: null,
          originPresetId: null,
        );
      }
      expect((await repository.load()).configuration.preampDb, -7);
      expect((await repository.load()).legacyResetNotice, isTrue);
      expect(
        (await database
                .customSelect('SELECT count(*) AS count FROM eq_state')
                .getSingle())
            .read<int>('count'),
        1,
      );
    },
    skip: !sqliteAvailable,
  );
  test(
    'duplicate storage names fail instead of replacing another identity',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final repository = EqRepository(database.eqDao);
      await repository.savePreset(
        EqPreset(
          id: 'original',
          name: 'Car',
          configuration: EqConfiguration.flat(),
        ),
      );
      await expectLater(
        repository.savePreset(
          EqPreset(
            id: 'other',
            name: 'CAR',
            configuration: EqConfiguration.flat(mode: EqMode.tenBand),
          ),
        ),
        throwsA(isA<Exception>()),
      );
      expect((await repository.load()).presets.single.id, 'original');
    },
    skip: !sqliteAvailable,
  );
  test('corrupt records are retained; loading fails safely and leaves audio disabled', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await database.eqDao.savePreset(
      id: 'broken',
      name: 'Broken',
      presetJson: '{wrong',
    );
    await database.eqDao.saveState(
      configurationJson: '{wrong',
      selectedPresetId: 'broken',
      originPresetId: 'broken',
    );
    final stored = await EqRepository(database.eqDao).load();
    expect(stored.configuration.enabled, isFalse);
    expect(stored.presets, isEmpty);
    expect(stored.recoveryMessage, isNotNull);
    expect((await database.eqDao.getPresets()).single.presetJson, '{wrong');
    expect((await database.eqDao.getState())!.configurationJson, '{wrong');
  }, skip: !sqliteAvailable);
}
