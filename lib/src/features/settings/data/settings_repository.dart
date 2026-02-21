import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';

class SettingsRepository {
  SettingsRepository(this._dao);

  final AppSettingsDao _dao;

  Stream<AppSettingsModel> watchSettings() {
    return _dao.watchSettings().map(_mapOrDefault);
  }

  Future<AppSettingsModel> getSettings() async {
    final row = await _dao.getSettings();
    return _mapOrDefault(row);
  }

  Future<void> saveSettings(AppSettingsModel settings) {
    // skipSilenceEnabled is persisted for compatibility with older schema
    // versions but is currently not applied at runtime playback level.
    return _dao.saveSettings(
      wifiMaxBitRate: settings.wifiMaxBitRate,
      wifiFormat: settings.wifiFormat,
      cellularMaxBitRate: settings.cellularMaxBitRate,
      cellularFormat: settings.cellularFormat,
      scrobbleEnabled: settings.scrobbleEnabled,
      gaplessEnabled: settings.gaplessEnabled,
      skipSilenceEnabled: settings.skipSilenceEnabled,
    );
  }

  Future<void> resetDefaults() => _dao.resetDefaults();

  AppSettingsModel _mapOrDefault(AppSettingsTableData? row) {
    if (row == null) {
      return const AppSettingsModel.defaults();
    }
    return AppSettingsModel(
      wifiMaxBitRate: row.wifiMaxBitRate,
      wifiFormat: row.wifiFormat,
      cellularMaxBitRate: row.cellularMaxBitRate,
      cellularFormat: row.cellularFormat,
      scrobbleEnabled: row.scrobbleEnabled,
      gaplessEnabled: row.gaplessEnabled,
      skipSilenceEnabled: row.skipSilenceEnabled,
    );
  }
}
