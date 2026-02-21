import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:sqlite3/sqlite3.dart';

bool get _sqliteAvailable {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } on Object {
    return false;
  }
}

void main() {
  group('AppSettingsDao', () {
    late NavisDatabase database;

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'saveSettings writes and overwrites single-row settings',
      () async {
        await database.appSettingsDao.saveSettings(
          wifiMaxBitRate: 320,
          wifiFormat: 'opus',
          cellularMaxBitRate: 128,
          cellularFormat: 'aac',
          scrobbleEnabled: false,
          gaplessEnabled: false,
          skipSilenceEnabled: true,
        );

        final first = await database.appSettingsDao.getSettings();
        expect(first, isNotNull);
        expect(first!.id, AppSettingsDao.primarySettingsId);
        expect(first.wifiMaxBitRate, 320);
        expect(first.wifiFormat, 'opus');
        expect(first.cellularMaxBitRate, 128);
        expect(first.cellularFormat, 'aac');
        expect(first.scrobbleEnabled, isFalse);
        expect(first.gaplessEnabled, isFalse);
        expect(first.skipSilenceEnabled, isTrue);

        await database.appSettingsDao.saveSettings(
          wifiMaxBitRate: null,
          wifiFormat: null,
          cellularMaxBitRate: 192,
          cellularFormat: 'mp3',
          scrobbleEnabled: true,
          gaplessEnabled: true,
          skipSilenceEnabled: false,
        );

        final second = await database.appSettingsDao.getSettings();
        expect(second, isNotNull);
        expect(second!.id, AppSettingsDao.primarySettingsId);
        expect(second.wifiMaxBitRate, isNull);
        expect(second.wifiFormat, isNull);
        expect(second.cellularMaxBitRate, 192);
        expect(second.cellularFormat, 'mp3');
        expect(second.scrobbleEnabled, isTrue);
        expect(second.gaplessEnabled, isTrue);
        expect(second.skipSilenceEnabled, isFalse);
      },
      skip: !_sqliteAvailable,
    );

    test('resetDefaults restores app defaults', () async {
      await database.appSettingsDao.saveSettings(
        wifiMaxBitRate: 320,
        wifiFormat: 'opus',
        cellularMaxBitRate: 96,
        cellularFormat: 'aac',
        scrobbleEnabled: false,
        gaplessEnabled: false,
        skipSilenceEnabled: true,
      );

      await database.appSettingsDao.resetDefaults();

      final settings = await database.appSettingsDao.getSettings();
      expect(settings, isNotNull);
      expect(settings!.wifiMaxBitRate, isNull);
      expect(settings.wifiFormat, isNull);
      expect(
        settings.cellularMaxBitRate,
        AppSettingsDao.defaultCellularBitRate,
      );
      expect(settings.cellularFormat, AppSettingsDao.defaultCellularFormat);
      expect(settings.scrobbleEnabled, isTrue);
      expect(settings.gaplessEnabled, isTrue);
      expect(settings.skipSilenceEnabled, isFalse);
    }, skip: !_sqliteAvailable);
  });
}
