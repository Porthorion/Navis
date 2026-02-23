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
    required bool showRadioPage,
    required bool equalizerEnabled,
    String? equalizerBandGains,
    required bool loudnessEnabled,
    double? loudnessTargetGainDb,
    required bool wifiOnlyDownloads,
    required String themeMode,
    int? colorSchemeSeed,
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
        showRadioPage: Value(showRadioPage),
        equalizerEnabled: Value(equalizerEnabled),
        equalizerBandGains: Value(equalizerBandGains),
        loudnessEnabled: Value(loudnessEnabled),
        loudnessTargetGainDb: Value(loudnessTargetGainDb),
        wifiOnlyDownloads: Value(wifiOnlyDownloads),
        themeMode: Value(themeMode),
        colorSchemeSeed: Value(colorSchemeSeed),
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
      showRadioPage: true,
      equalizerEnabled: false,
      equalizerBandGains: null,
      loudnessEnabled: false,
      loudnessTargetGainDb: 0,
      wifiOnlyDownloads: false,
      themeMode: 'dark',
      colorSchemeSeed: null,
    );
  }

  // ---------------------------------------------------------------------------
  // Cache budget helpers
  // ---------------------------------------------------------------------------

  static const int defaultRollingCacheBudgetMb = 2048;

  /// Targeted update for rolling cache budget without touching other settings.
  Future<void> updateRollingCacheBudgetMb(int mb) {
    return (update(appSettingsTable)
          ..where((t) => t.id.equals(primarySettingsId)))
        .write(
      AppSettingsTableCompanion(
        rollingCacheBudgetMb: Value(mb),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Stream the rolling cache budget in MB.
  Stream<int> watchRollingCacheBudgetMb() {
    return watchSettings()
        .map((s) => s?.rollingCacheBudgetMb ?? defaultRollingCacheBudgetMb);
  }

  /// Read current rolling cache budget in MB (one-shot).
  Future<int> getRollingCacheBudgetMb() async {
    final s = await getSettings();
    return s?.rollingCacheBudgetMb ?? defaultRollingCacheBudgetMb;
  }

  // ---------------------------------------------------------------------------
  // Wi-Fi-only downloads helpers
  // ---------------------------------------------------------------------------

  /// Targeted update for the Wi-Fi-only downloads flag.
  Future<void> updateWifiOnlyDownloads({required bool enabled}) {
    return (update(appSettingsTable)
          ..where((t) => t.id.equals(primarySettingsId)))
        .write(
      AppSettingsTableCompanion(
        wifiOnlyDownloads: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Stream the Wi-Fi-only downloads setting.
  Stream<bool> watchWifiOnlyDownloads() {
    return watchSettings().map((s) => s?.wifiOnlyDownloads ?? false);
  }

  // ---------------------------------------------------------------------------
  // Theme helpers
  // ---------------------------------------------------------------------------

  /// Targeted update for theme mode.
  Future<void> updateThemeMode(String mode) {
    return (update(appSettingsTable)
          ..where((t) => t.id.equals(primarySettingsId)))
        .write(
      AppSettingsTableCompanion(
        themeMode: Value(mode),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for color scheme seed.
  Future<void> updateColorSchemeSeed(int? seed) {
    return (update(appSettingsTable)
          ..where((t) => t.id.equals(primarySettingsId)))
        .write(
      AppSettingsTableCompanion(
        colorSchemeSeed: Value(seed),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Stream the current theme mode.
  Stream<String> watchThemeMode() {
    return watchSettings().map((s) => s?.themeMode ?? 'dark');
  }

  /// Stream the current color scheme seed.
  Stream<int?> watchColorSchemeSeed() {
    return watchSettings().map((s) => s?.colorSchemeSeed);
  }
}
