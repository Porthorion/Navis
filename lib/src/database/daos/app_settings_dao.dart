import 'package:drift/drift.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/domain/download_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:navis/src/database/tables/app_settings_table.dart';

part 'app_settings_dao.g.dart';

typedef GroupListeningSettingsRecord = ({
  bool groupListeningEnabled,
  String? voyageServerUrl,
  String? voyageDisplayName,
  String? voyageDeviceLabel,
  bool voyageAutoFollowHost,
});

const bool _cloneDiagnostics =
    bool.fromEnvironment('NAVIS_SYNC_DIAGNOSTICS') &&
    String.fromEnvironment('NAVIS_SYNC_DIAGNOSTICS_MODE') == 'clone';
const String _diagnosticsRoot = String.fromEnvironment(
  'NAVIS_SYNC_DIAGNOSTICS_ROOT',
);

/// A clone diagnostics profile is a copy of a real profile, so its settings
/// can name the user's own downloads folder, and the download service would
/// move the clone's downloads into it. In a clone, a filesystem download
/// folder outside the diagnostics root therefore reads as unset; folders the
/// diagnostics create inside the root, and Android tree URIs (whose grants
/// belong to the real app), are kept.
@visibleForTesting
AppSettingsTableData? isolateCloneDownloadFolder(
  AppSettingsTableData? row, {
  required bool cloneDiagnostics,
  required String diagnosticsRoot,
}) {
  final path = row?.customDownloadFolderPath?.trim();
  if (row == null ||
      !cloneDiagnostics ||
      diagnosticsRoot.isEmpty ||
      path == null ||
      path.isEmpty ||
      path.startsWith('content://') ||
      p.isWithin(
        p.normalize(p.absolute(diagnosticsRoot)),
        p.normalize(p.absolute(path)),
      )) {
    return row;
  }
  return row.copyWith(
    customDownloadFolderEnabled: false,
    customDownloadFolderPath: const Value(null),
  );
}

@DriftAccessor(tables: [AppSettingsTable])
class AppSettingsDao extends DatabaseAccessor<NavisDatabase>
    with _$AppSettingsDaoMixin {
  new(super.attachedDatabase);

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
    return query.watchSingleOrNull().map(_isolateCloneDownloadFolder);
  }

  Future<AppSettingsTableData?> getSettings() async {
    final query = select(appSettingsTable)
      ..where((table) => table.id.equals(primarySettingsId))
      ..limit(1);
    return _isolateCloneDownloadFolder(await query.getSingleOrNull());
  }

  static AppSettingsTableData? _isolateCloneDownloadFolder(
    AppSettingsTableData? row,
  ) => isolateCloneDownloadFolder(
    row,
    cloneDiagnostics: _cloneDiagnostics,
    diagnosticsRoot: _diagnosticsRoot,
  );

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
    double? playbackSpeed,
    int? albumGridDensity,
    String gridArtworkSize = 'auto',
    bool homeRecommendationsAutoAdvance = false,
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
    bool albumQueueEnabled = true,
    bool matchFlowEnabled = false,
    bool likedQueueEnabled = true,
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
        playbackSpeed: playbackSpeed == null
            ? const Value.absent()
            : Value(playbackSpeed),
        albumGridDensity: Value(albumGridDensity),
        gridArtworkSize: Value(gridArtworkSize),
        homeRecommendationsAutoAdvance: Value(homeRecommendationsAutoAdvance),
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

  Future<void> updatePlaybackAdjustments({
    required double speed,
    required double pitchSemitones,
    bool lockPitchToSpeed = false,
    required String? selectedPresetId,
    String? presetsJson,
  }) async {
    await getSettings();
    await (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        playbackSpeed: Value(speed),
        playbackPitchSemitones: Value(pitchSemitones),
        lockPitchToSpeed: Value(lockPitchToSpeed),
        selectedPlaybackPresetId: Value(selectedPresetId),
        playbackPresets: presetsJson == null
            ? const Value.absent()
            : Value(presetsJson),
      ),
    );
  }

  Future<void> resetDefaults() async {
    await updatePlaybackAdjustments(
      speed: 1,
      pitchSemitones: 0,
      selectedPresetId: 'none',
    );
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
      albumQueueEnabled: true,
      matchFlowEnabled: false,
      likedQueueEnabled: true,
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

  Stream<int> watchOnboardingVersion() {
    return watchSettings().map((settings) => settings?.onboardingVersion ?? 0);
  }

  Future<void> completeOnboarding(int version) {
    return (update(
      appSettingsTable,
    )..where((table) => table.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        onboardingVersion: Value(version),
        updatedAt: Value(DateTime.now()),
      ),
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

  Future<void> updateCustomDownloadFolderStorageKind(String kind) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        customDownloadFolderStorageKind: Value(kind),
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
  // Download preference helpers (targeted only; full-draft saves never write
  // these columns)
  // ---------------------------------------------------------------------------

  static DownloadQualityPreference _downloadQualityOf(
    AppSettingsTableData? s,
  ) => DownloadQualityPreference.fromStored(
    mode: s?.downloadQualityMode,
    bitRate: s?.downloadMaxBitRate,
    format: s?.downloadFormat,
    prompted: s?.downloadQualityPrompted,
  );

  Stream<DownloadQualityPreference> watchDownloadQualityPreference() =>
      watchSettings().map(_downloadQualityOf).distinct();

  Future<DownloadQualityPreference> getDownloadQualityPreference() async =>
      _downloadQualityOf(await getSettings());

  /// Saves the download quality. Null [bitRate] or [format] keeps the stored
  /// value, so choosing Original keeps the transcode format for the picker.
  Future<void> updateDownloadQuality({
    required DownloadQualityMode mode,
    int? bitRate,
    String? format,
  }) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        downloadQualityMode: Value(mode.name),
        downloadMaxBitRate: bitRate == null
            ? const Value.absent()
            : Value(bitRate),
        downloadFormat: format == null ? const Value.absent() : Value(format),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Saves the transcode format alone (used by the picker in every mode).
  Future<void> updateDownloadFormat(String format) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        downloadFormat: Value(format),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> updateDownloadQualityPrompted({required bool prompted}) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        downloadQualityPrompted: Value(prompted),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> updateMaxConcurrentDownloads(int value) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        maxConcurrentDownloads: Value(sanitizeConcurrentDownloads(value)),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Stream<int> watchMaxConcurrentDownloads() => watchSettings()
      .map((s) => sanitizeConcurrentDownloads(s?.maxConcurrentDownloads))
      .distinct();

  Future<int> getMaxConcurrentDownloads() async => sanitizeConcurrentDownloads(
    (await getSettings())?.maxConcurrentDownloads,
  );

  Future<void> updateDownloadsPaused({required bool paused}) {
    return (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        downloadsPaused: Value(paused),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Stream<bool> watchDownloadsPaused() =>
      watchSettings().map((s) => s?.downloadsPaused ?? false).distinct();

  Future<bool> getDownloadsPaused() async =>
      (await getSettings())?.downloadsPaused ?? false;

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

  Future<void> updateGridArtworkSize(String size) async {
    await getSettings();
    await (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        gridArtworkSize: Value(size),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> updateHomeRecommendationsAutoAdvance({
    required bool enabled,
  }) async {
    await getSettings();
    await (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        homeRecommendationsAutoAdvance: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Targeted update for legacy album grid density (null = auto).
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
  // Keep the existing method and callback call contract for callers.
  // ignore: avoid_positional_boolean_parameters
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

  Future<void> updateLastFmScrobblingState({bool? enabled, bool? connected}) {
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
