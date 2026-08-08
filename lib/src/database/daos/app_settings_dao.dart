import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/app_settings_table.dart';

part 'app_settings_dao.g.dart';

typedef GroupListeningSettingsRecord = ({
  bool groupListeningEnabled,
  String? voyageServerUrl,
  String? voyageDisplayName,
  String? voyageDeviceLabel,
  bool voyageAutoFollowHost,
});

@DriftAccessor(tables: [AppSettingsTable])
class AppSettingsDao extends DatabaseAccessor<NavisDatabase>
    with _$AppSettingsDaoMixin {
  AppSettingsDao(super.db);

  static const int primarySettingsId = 1;
  static const int defaultCellularBitRate = 192;
  static const String defaultCellularFormat = 'opus';
  static const int defaultSyncIntervalMinutes = 60;
  static const double defaultDesktopPlaybackVolume = 1;
  static const bool defaultVoyageAutoFollowHost = true;

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

  Future<GroupListeningSettingsRecord> getGroupListeningSettings() async {
    final row = await customSelect(
      '''
      SELECT
        group_listening_enabled,
        voyage_server_url,
        voyage_display_name,
        voyage_device_label,
        voyage_auto_follow_host
      FROM app_settings
      WHERE id = ?
      LIMIT 1;
      ''',
      variables: <Variable<Object>>[Variable<int>(primarySettingsId)],
      readsFrom: {appSettingsTable},
    ).getSingleOrNull();
    final data = row?.data ?? const <String, Object?>{};
    return (
      groupListeningEnabled:
          (data['group_listening_enabled'] as int? ?? 0) != 0,
      voyageServerUrl: data['voyage_server_url'] as String?,
      voyageDisplayName: data['voyage_display_name'] as String?,
      voyageDeviceLabel: data['voyage_device_label'] as String?,
      voyageAutoFollowHost: (data['voyage_auto_follow_host'] as int? ?? 1) != 0,
    );
  }

  Future<void> saveSettings({
    int? wifiMaxBitRate,
    String? wifiFormat,
    int? cellularMaxBitRate,
    String? cellularFormat,
    required bool cachedPlaybackFirst,
    required bool scrobbleEnabled,
    required bool gaplessEnabled,
    required bool skipSilenceEnabled,
    required bool showAlbumsPage,
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
    required bool customDownloadFolderEnabled,
    String? customDownloadFolderPath,
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
    bool backgroundSyncUnmeteredOnly = true,
    required bool useLrclib,
    required bool legacyInstantMixEnabled,
    required String replayGainMode,
    required double replayGainPreamp,
    required double playbackSpeed,
    int? albumGridDensity,
    required String coverArtShape,
    required String nowPlayingArtShape,
    required String artistCardShape,
    required String artistViewMode,
    bool desktopFocusPlayerModeEnabled = false,
    double desktopPlaybackVolume = defaultDesktopPlaybackVolume,
    double desktopLastAudibleVolume = defaultDesktopPlaybackVolume,
    required String homeDensity,
    String? homeSectionOrder,
    String? homeSectionsHidden,
    String? libraryPageOrder,
    String desktopNavbarStyle = 'comfortable',
    bool desktopNavbarAutohide = false,
    bool albumQueueEnabled = false,
    bool matchFlowEnabled = false,
    bool likedQueueEnabled = false,
    String? lastFmApiKey,
    bool lastFmScrobblingEnabled = false,
    bool lastFmSessionConnected = false,
    bool listenBrainzScrobblingEnabled = false,
    bool listenBrainzTokenValid = false,
    String? listenBrainzUserName,
    String? customVoyageServers,
  }) {
    return into(appSettingsTable).insertOnConflictUpdate(
      AppSettingsTableCompanion.insert(
        id: Value(primarySettingsId),
        wifiMaxBitRate: Value(wifiMaxBitRate),
        wifiFormat: Value(wifiFormat),
        cellularMaxBitRate: Value(cellularMaxBitRate),
        cellularFormat: Value(cellularFormat),
        cachedPlaybackFirst: Value(cachedPlaybackFirst),
        scrobbleEnabled: Value(scrobbleEnabled),
        gaplessEnabled: Value(gaplessEnabled),
        skipSilenceEnabled: Value(skipSilenceEnabled),
        showAlbumsPage: Value(showAlbumsPage),
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
        customDownloadFolderEnabled: Value(customDownloadFolderEnabled),
        customDownloadFolderPath: Value(customDownloadFolderPath),
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
        backgroundSyncUnmeteredOnly: Value(backgroundSyncUnmeteredOnly),
        useLrclib: Value(useLrclib),
        legacyInstantMixEnabled: Value(legacyInstantMixEnabled),
        replayGainMode: Value(replayGainMode),
        replayGainPreamp: Value(replayGainPreamp),
        playbackSpeed: Value(playbackSpeed),
        albumGridDensity: Value(albumGridDensity),
        coverArtShape: Value(coverArtShape),
        nowPlayingArtShape: Value(nowPlayingArtShape),
        artistCardShape: Value(artistCardShape),
        artistViewMode: Value(artistViewMode),
        desktopFocusPlayerModeEnabled: Value(desktopFocusPlayerModeEnabled),
        desktopPlaybackVolume: Value(desktopPlaybackVolume),
        desktopLastAudibleVolume: Value(desktopLastAudibleVolume),
        homeDensity: Value(homeDensity),
        homeSectionOrder: Value(homeSectionOrder),
        homeSectionsHidden: Value(homeSectionsHidden),
        libraryPageOrder: Value(libraryPageOrder),
        desktopNavbarStyle: Value(desktopNavbarStyle),
        desktopNavbarAutohide: Value(desktopNavbarAutohide),
        albumQueueEnabled: Value(albumQueueEnabled),
        matchFlowEnabled: Value(matchFlowEnabled),
        likedQueueEnabled: Value(likedQueueEnabled),
        lastFmApiKey: Value(lastFmApiKey),
        lastFmScrobblingEnabled: Value(lastFmScrobblingEnabled),
        lastFmSessionConnected: Value(lastFmSessionConnected),
        listenBrainzScrobblingEnabled: Value(listenBrainzScrobblingEnabled),
        listenBrainzTokenValid: Value(listenBrainzTokenValid),
        listenBrainzUserName: Value(listenBrainzUserName),
        customVoyageServers: Value(customVoyageServers),
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<void> saveGroupListeningSettings({
    required bool groupListeningEnabled,
    String? voyageServerUrl,
    String? voyageDisplayName,
    String? voyageDeviceLabel,
    bool voyageAutoFollowHost = defaultVoyageAutoFollowHost,
  }) async {
    final updatedAt = DateTime.now();
    await customUpdate(
      '''
      INSERT INTO app_settings (
        id,
        updated_at,
        group_listening_enabled,
        voyage_server_url,
        voyage_display_name,
        voyage_device_label,
        voyage_auto_follow_host
      ) VALUES (?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), ?)
      ON CONFLICT(id) DO UPDATE SET
        updated_at = excluded.updated_at,
        group_listening_enabled = excluded.group_listening_enabled,
        voyage_server_url = excluded.voyage_server_url,
        voyage_display_name = excluded.voyage_display_name,
        voyage_device_label = excluded.voyage_device_label,
        voyage_auto_follow_host = excluded.voyage_auto_follow_host;
      ''',
      variables: <Variable<Object>>[
        Variable<int>(primarySettingsId),
        Variable<DateTime>(updatedAt),
        Variable<int>(groupListeningEnabled ? 1 : 0),
        Variable<String>(voyageServerUrl ?? ''),
        Variable<String>(voyageDisplayName ?? ''),
        Variable<String>(voyageDeviceLabel ?? ''),
        Variable<int>(voyageAutoFollowHost ? 1 : 0),
      ],
      updates: {appSettingsTable},
    );
  }

  Future<void> resetDefaults() async {
    await saveSettings(
      wifiMaxBitRate: null,
      wifiFormat: null,
      cellularMaxBitRate: defaultCellularBitRate,
      cellularFormat: defaultCellularFormat,
      cachedPlaybackFirst: false,
      scrobbleEnabled: true,
      gaplessEnabled: true,
      skipSilenceEnabled: false,
      showAlbumsPage: true,
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
      customDownloadFolderEnabled: false,
      customDownloadFolderPath: null,
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
      backgroundSyncUnmeteredOnly: true,
      useLrclib: true,
      legacyInstantMixEnabled: false,
      replayGainMode: 'off',
      replayGainPreamp: 0,
      playbackSpeed: 1,
      albumGridDensity: null,
      coverArtShape: 'square',
      nowPlayingArtShape: 'rounded',
      artistCardShape: 'circle',
      artistViewMode: 'grid',
      desktopFocusPlayerModeEnabled: false,
      desktopPlaybackVolume: defaultDesktopPlaybackVolume,
      desktopLastAudibleVolume: defaultDesktopPlaybackVolume,
      homeDensity: 'comfortable',
      homeSectionOrder: null,
      homeSectionsHidden: null,
      libraryPageOrder: null,
      desktopNavbarStyle: 'comfortable',
      desktopNavbarAutohide: false,
      albumQueueEnabled: false,
      matchFlowEnabled: false,
      likedQueueEnabled: false,
      lastFmApiKey: null,
      lastFmScrobblingEnabled: false,
      lastFmSessionConnected: false,
      listenBrainzScrobblingEnabled: false,
      listenBrainzTokenValid: false,
      customVoyageServers: null,
    );
    await saveGroupListeningSettings(
      groupListeningEnabled: false,
      voyageServerUrl: null,
      voyageDisplayName: null,
      voyageDeviceLabel: null,
      voyageAutoFollowHost: defaultVoyageAutoFollowHost,
    );
  }

  // ---------------------------------------------------------------------------
  // Page visibility helpers
  // ---------------------------------------------------------------------------

  /// Targeted update for show albums page.
  Future<void> updateShowAlbumsPage({required bool enabled}) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        showAlbumsPage: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

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

  /// Targeted update for the custom permanent-download-folder toggle.
  Future<void> updateCustomDownloadFolderEnabled({required bool enabled}) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        customDownloadFolderEnabled: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for the custom permanent-download-folder path.
  Future<void> updateCustomDownloadFolderPath(String? path) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        customDownloadFolderPath: Value(path),
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

  /// Stream the custom permanent-download-folder toggle.
  Stream<bool> watchCustomDownloadFolderEnabled() {
    return watchSettings().map((s) => s?.customDownloadFolderEnabled ?? false);
  }

  /// Stream the custom permanent-download-folder path.
  Stream<String?> watchCustomDownloadFolderPath() {
    return watchSettings().map((s) => s?.customDownloadFolderPath);
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

  /// Targeted update for background sync unmetered-only preference.
  Future<void> updateBackgroundSyncUnmeteredOnly({required bool enabled}) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        backgroundSyncUnmeteredOnly: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Stream whether background sync waits for unmetered networks.
  Stream<bool> watchBackgroundSyncUnmeteredOnly() {
    return watchSettings().map((s) => s?.backgroundSyncUnmeteredOnly ?? true);
  }

  // ---------------------------------------------------------------------------
  // Appearance personalization helpers
  // ---------------------------------------------------------------------------

  /// Targeted update for album grid density (null = auto).
  Future<void> updateAlbumGridDensity(int? density) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        albumGridDensity: Value(density),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for library cover art shape ('square', 'rounded', 'circle').
  Future<void> updateCoverArtShape(String shape) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        coverArtShape: Value(shape),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for Now Playing art shape ('square', 'rounded', 'circle').
  Future<void> updateNowPlayingArtShape(String shape) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        nowPlayingArtShape: Value(shape),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for artist card shape ('square', 'rounded', 'circle').
  Future<void> updateArtistCardShape(String shape) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        artistCardShape: Value(shape),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for artist view mode ('grid' or 'list').
  Future<void> updateArtistViewMode(String mode) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        artistViewMode: Value(mode),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for home section density ('comfortable' or 'compact').
  Future<void> updateHomeDensity(String density) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        homeDensity: Value(density),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for home section order (JSON string list, or null for default).
  Future<void> updateHomeSectionOrder(String? json) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        homeSectionOrder: Value(json),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for hidden home sections (JSON string list, or null for none).
  Future<void> updateHomeSectionsHidden(String? json) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        homeSectionsHidden: Value(json),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for library page order (JSON string list, or null for default).
  Future<void> updateLibraryPageOrder(String? json) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        libraryPageOrder: Value(json),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for desktop navigation sidebar style.
  Future<void> updateDesktopNavbarStyle(String style) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        desktopNavbarStyle: Value(style),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for desktop navigation sidebar autohide.
  Future<void> updateDesktopNavbarAutohide(bool enabled) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        desktopNavbarAutohide: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Atomically persists the current desktop volume and its unmute target.
  Future<void> updateDesktopPlaybackVolume({
    required double volume,
    required double lastAudibleVolume,
  }) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        desktopPlaybackVolume: Value(volume),
        desktopLastAudibleVolume: Value(lastAudibleVolume),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Returns the app version+build string recorded at the time of the last
  /// version-triggered forced full sync. Null if no such sync has run yet.
  Future<String?> getLastFullSyncAppBuild() async {
    final row = await getSettings();
    return row?.lastFullSyncAppBuild;
  }

  /// Persists [versionBuild] as the app version active during the last forced
  /// full sync, so subsequent startups can skip the forced resync.
  Future<void> setLastFullSyncAppBuild(String versionBuild) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        lastFullSyncAppBuild: Value(versionBuild),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> updateLastFmScrobblingState({
    bool? enabled,
    bool? connected,
  }) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        lastFmScrobblingEnabled: enabled == null
            ? const Value.absent()
            : Value(enabled),
        lastFmSessionConnected: connected == null
            ? const Value.absent()
            : Value(connected),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> updateListenBrainzScrobblingState({
    bool? enabled,
    bool? tokenValid,
    String? userName,
    bool clearUserName = false,
  }) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        listenBrainzScrobblingEnabled: enabled == null
            ? const Value.absent()
            : Value(enabled),
        listenBrainzTokenValid: tokenValid == null
            ? const Value.absent()
            : Value(tokenValid),
        listenBrainzUserName: clearUserName
            ? const Value(null)
            : userName == null
            ? const Value.absent()
            : Value(userName),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}
