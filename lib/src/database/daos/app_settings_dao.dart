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
  static const String defaultCellularFormat = 'opus';
  static const int defaultSyncIntervalMinutes = 60;

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
    required bool showPlaylistsPage,
    required bool showArtistsPage,
    required bool showLikedPage,
    required bool equalizerEnabled,
    String? equalizerBandGains,
    required bool loudnessEnabled,
    double? loudnessTargetGainDb,
    required bool wifiOnlyDownloads,
    required bool autoDownloadStarredOnWifi,
    required String themeMode,
    int? colorSchemeSeed,
    String? appLocale,
    required bool crossfadeEnabled,
    required int crossfadeDurationSeconds,
    required String crossfadeType,
    required bool artTintedNowPlaying,
    required bool dynamicAlbumColorEnabled,
    required bool updateCheckEnabled,
    required String updateChannel,
    String? audioMuseServerUrl,
    String? audioMuseApiKey,
    required bool audioMuseEnabled,
    required int syncIntervalMinutes,
    required String replayGainMode,
    required double replayGainPreamp,
    required double playbackSpeed,
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
        showPlaylistsPage: Value(showPlaylistsPage),
        showArtistsPage: Value(showArtistsPage),
        showLikedPage: Value(showLikedPage),
        equalizerEnabled: Value(equalizerEnabled),
        equalizerBandGains: Value(equalizerBandGains),
        loudnessEnabled: Value(loudnessEnabled),
        loudnessTargetGainDb: Value(loudnessTargetGainDb),
        wifiOnlyDownloads: Value(wifiOnlyDownloads),
        autoDownloadStarredOnWifi: Value(autoDownloadStarredOnWifi),
        themeMode: Value(themeMode),
        colorSchemeSeed: Value(colorSchemeSeed),
        appLocale: Value(appLocale),
        crossfadeEnabled: Value(crossfadeEnabled),
        crossfadeDurationSeconds: Value(crossfadeDurationSeconds),
        crossfadeType: Value(crossfadeType),
        artTintedNowPlaying: Value(artTintedNowPlaying),
        dynamicAlbumColorEnabled: Value(dynamicAlbumColorEnabled),
        updateCheckEnabled: Value(updateCheckEnabled),
        updateChannel: Value(updateChannel),
        audioMuseServerUrl: Value(audioMuseServerUrl),
        audioMuseApiKey: Value(audioMuseApiKey),
        audioMuseEnabled: Value(audioMuseEnabled),
        syncIntervalMinutes: Value(syncIntervalMinutes),
        replayGainMode: Value(replayGainMode),
        replayGainPreamp: Value(replayGainPreamp),
        playbackSpeed: Value(playbackSpeed),
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
      showPlaylistsPage: true,
      showArtistsPage: true,
      showLikedPage: true,
      equalizerEnabled: false,
      equalizerBandGains: null,
      loudnessEnabled: false,
      loudnessTargetGainDb: 0,
      wifiOnlyDownloads: true,
      autoDownloadStarredOnWifi: false,
      themeMode: 'dark',
      colorSchemeSeed: null,
      appLocale: null,
      crossfadeEnabled: false,
      crossfadeDurationSeconds: 5,
      crossfadeType: 'normal',
      artTintedNowPlaying: true,
      dynamicAlbumColorEnabled: false,
      updateCheckEnabled: true,
      updateChannel: 'stable',
      audioMuseEnabled: false,
      syncIntervalMinutes: defaultSyncIntervalMinutes,
      replayGainMode: 'off',
      replayGainPreamp: 0,
      playbackSpeed: 1,
    );
  }

  // ---------------------------------------------------------------------------
  // Page visibility helpers
  // ---------------------------------------------------------------------------

  /// Targeted update for show radio page.
  Future<void> updateShowRadioPage({required bool enabled}) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        showRadioPage: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for show playlists page.
  Future<void> updateShowPlaylistsPage({required bool enabled}) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        showPlaylistsPage: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for show artists page.
  Future<void> updateShowArtistsPage({required bool enabled}) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        showArtistsPage: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for show liked page.
  Future<void> updateShowLikedPage({required bool enabled}) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        showLikedPage: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Cache budget helpers
  // ---------------------------------------------------------------------------

  static const int defaultRollingCacheBudgetMb = 2048;

  /// Targeted update for rolling cache budget without touching other settings.
  Future<void> updateRollingCacheBudgetMb(int mb) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        rollingCacheBudgetMb: Value(mb),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Stream the rolling cache budget in MB.
  Stream<int> watchRollingCacheBudgetMb() {
    return watchSettings().map(
      (s) => s?.rollingCacheBudgetMb ?? defaultRollingCacheBudgetMb,
    );
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
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        wifiOnlyDownloads: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for the auto-download liked content flag.
  Future<void> updateAutoDownloadStarredOnWifi({required bool enabled}) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        autoDownloadStarredOnWifi: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Stream the Wi-Fi-only downloads setting.
  Stream<bool> watchWifiOnlyDownloads() {
    return watchSettings().map((s) => s?.wifiOnlyDownloads ?? true);
  }

  /// Stream the show liked page setting.
  Stream<bool> watchShowLikedPage() {
    return watchSettings().map((s) => s?.showLikedPage ?? true);
  }

  /// Stream the auto-download liked on Wi-Fi setting.
  Stream<bool> watchAutoDownloadStarredOnWifi() {
    return watchSettings().map((s) => s?.autoDownloadStarredOnWifi ?? false);
  }

  // ---------------------------------------------------------------------------
  // Theme helpers
  // ---------------------------------------------------------------------------

  /// Targeted update for theme mode.
  Future<void> updateThemeMode(String mode) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        themeMode: Value(mode),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for color scheme seed.
  Future<void> updateColorSchemeSeed(int? seed) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        colorSchemeSeed: Value(seed),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for locale override code.
  Future<void> updateAppLocale(String? localeCode) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        appLocale: Value(localeCode),
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

  /// Stream the current locale override code.
  Stream<String?> watchAppLocale() {
    return watchSettings().map((s) => s?.appLocale);
  }

  // ---------------------------------------------------------------------------
  // Custom color presets helpers
  // ---------------------------------------------------------------------------

  /// Targeted update for custom color presets (JSON string of int list).
  Future<void> updateCustomColorPresets(String? json) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        customColorPresets: Value(json),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Stream the custom color presets JSON.
  Stream<String?> watchCustomColorPresets() {
    return watchSettings().map((s) => s?.customColorPresets);
  }

  // ---------------------------------------------------------------------------
  // Cover art cache helpers
  // ---------------------------------------------------------------------------

  /// Default for cover art cache max objects.
  /// 0 = unlimited (the cache manager will use a very large number internally).
  static const int defaultCoverArtCacheMaxObjects = 0;

  /// Targeted update for cover art cache max objects.
  Future<void> updateCoverArtCacheMaxObjects(int maxObjects) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        coverArtCacheMaxObjects: Value(maxObjects),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Stream the cover art cache max objects setting.
  Stream<int> watchCoverArtCacheMaxObjects() {
    return watchSettings().map(
      (s) => s?.coverArtCacheMaxObjects ?? defaultCoverArtCacheMaxObjects,
    );
  }

  /// Read current cover art cache max objects (one-shot).
  Future<int> getCoverArtCacheMaxObjects() async {
    final s = await getSettings();
    return s?.coverArtCacheMaxObjects ?? defaultCoverArtCacheMaxObjects;
  }

  // ---------------------------------------------------------------------------
  // Art-tinted Now Playing helpers
  // ---------------------------------------------------------------------------

  /// Targeted update for art-tinted Now Playing.
  Future<void> updateArtTintedNowPlaying({required bool enabled}) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        artTintedNowPlaying: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Stream the art-tinted Now Playing setting.
  Stream<bool> watchArtTintedNowPlaying() {
    return watchSettings().map((s) => s?.artTintedNowPlaying ?? true);
  }

  /// Targeted update for dynamic album-color theming.
  Future<void> updateDynamicAlbumColorEnabled({required bool enabled}) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        dynamicAlbumColorEnabled: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Stream the dynamic album-color setting.
  Stream<bool> watchDynamicAlbumColorEnabled() {
    return watchSettings().map((s) => s?.dynamicAlbumColorEnabled ?? false);
  }

  // ---------------------------------------------------------------------------
  // Sync interval helpers
  // ---------------------------------------------------------------------------

  /// Targeted update for sync interval minutes.
  Future<void> updateSyncIntervalMinutes(int minutes) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        syncIntervalMinutes: Value(minutes),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Stream the sync interval in minutes (0 = manual only).
  Stream<int> watchSyncIntervalMinutes() {
    return watchSettings().map(
      (s) => s?.syncIntervalMinutes ?? defaultSyncIntervalMinutes,
    );
  }

  /// Read current sync interval in minutes (one-shot).
  Future<int> getSyncIntervalMinutes() async {
    final s = await getSettings();
    return s?.syncIntervalMinutes ?? defaultSyncIntervalMinutes;
  }
}
