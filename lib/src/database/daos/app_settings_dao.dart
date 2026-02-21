import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/app_settings_table.dart';

part 'app_settings_dao.g.dart';

@DriftAccessor(tables: [AppSettingsTable])
class AppSettingsDao extends DatabaseAccessor<NavisDatabase>
    with _$AppSettingsDaoMixin {
  AppSettingsDao(super.db);

  static const int primarySettingsId = 1;
  static const int defaultCellularBitRate = 192;
  static const String defaultCellularFormat = 'mp3';

  Stream<AppSettingsTableData?> watchSettings() {
    final query = select(appSettingsTable)
      ..where((table) => table.id.equals(primarySettingsId))
      ..limit(1);
    return query.watchSingleOrNull();
  }

  Future<AppSettingsTableData?> getSettings() {
    final query = select(appSettingsTable)
      ..where((table) => table.id.equals(primarySettingsId))
      ..limit(1);
    return query.getSingleOrNull();
  }

  Future<void> saveSettings({
    int? wifiMaxBitRate,
    String? wifiFormat,
    int? cellularMaxBitRate,
    String? cellularFormat,
    required bool scrobbleEnabled,
    required bool gaplessEnabled,
    required bool skipSilenceEnabled,
  }) {
    return into(appSettingsTable).insertOnConflictUpdate(
      AppSettingsTableCompanion.insert(
        id: Value(primarySettingsId),
        wifiMaxBitRate: Value(wifiMaxBitRate),
        wifiFormat: Value(wifiFormat),
        cellularMaxBitRate: Value(cellularMaxBitRate),
        cellularFormat: Value(cellularFormat),
        scrobbleEnabled: Value(scrobbleEnabled),
        gaplessEnabled: Value(gaplessEnabled),
        skipSilenceEnabled: Value(skipSilenceEnabled),
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<void> resetDefaults() {
    return saveSettings(
      wifiMaxBitRate: null,
      wifiFormat: null,
      cellularMaxBitRate: defaultCellularBitRate,
      cellularFormat: defaultCellularFormat,
      scrobbleEnabled: true,
      gaplessEnabled: true,
      skipSilenceEnabled: false,
    );
  }
}
