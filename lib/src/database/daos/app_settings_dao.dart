import 'dart:convert';

import 'package:navis/src/features/settings/domain/appearance_presets.dart';

import 'package:drift/drift.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:navis/src/features/settings/domain/flat_areas.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/app_settings_table.dart';
import 'package:navis/src/features/downloads/domain/download_preferences.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/theme/navis_corner_style.dart';
import 'package:path/path.dart' as p;

part 'app_settings_dao.g.dart';

const bool _cloneDiagnostics =
    bool.fromEnvironment('NAVIS_SYNC_DIAGNOSTICS') &&
    String.fromEnvironment('NAVIS_SYNC_DIAGNOSTICS_MODE') == 'clone';
const String _diagnosticsRoot = String.fromEnvironment(
  'NAVIS_SYNC_DIAGNOSTICS_ROOT',
);

/// Whether a clone diagnostics build must not use [path] as its download
/// folder: a filesystem folder outside the diagnostics root, which can only
/// be the user's own. Android tree URIs, whose grants belong to the real app,
/// and folders the diagnostics create inside the root are allowed.
@visibleForTesting
bool cloneDownloadFolderOutsideRoot(
  String? path, {
  required bool cloneDiagnostics,
  required String diagnosticsRoot,
}) {
  final folder = path?.trim();
  return cloneDiagnostics &&
      diagnosticsRoot.isNotEmpty &&
      folder != null &&
      folder.isNotEmpty &&
      !folder.startsWith('content://') &&
      !p.isWithin(
        p.normalize(p.absolute(diagnosticsRoot)),
        p.normalize(p.absolute(folder)),
      );
}

/// [cloneDownloadFolderOutsideRoot] for this build; always false outside
/// clone diagnostics.
bool cloneRejectsDownloadFolder(String path) => cloneDownloadFolderOutsideRoot(
  path,
  cloneDiagnostics: _cloneDiagnostics,
  diagnosticsRoot: _diagnosticsRoot,
);

/// A clone diagnostics profile is a copy of a real profile, so its settings
/// can name the user's own downloads folder, and the download service would
/// move the clone's downloads into it. In a clone, such a folder (see
/// [cloneDownloadFolderOutsideRoot]) therefore reads as unset, and the
/// download service refuses to choose one.
@visibleForTesting
AppSettingsTableData? isolateCloneDownloadFolder(
  AppSettingsTableData? row, {
  required bool cloneDiagnostics,
  required String diagnosticsRoot,
}) {
  if (row == null ||
      !cloneDownloadFolderOutsideRoot(
        row.customDownloadFolderPath,
        cloneDiagnostics: cloneDiagnostics,
        diagnosticsRoot: diagnosticsRoot,
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
    with NavisDaoTransactions, _$AppSettingsDaoMixin {
  new(super.attachedDatabase);

  static const int primarySettingsId = 1;
  static const int defaultCellularBitRate = 192;
  static const String defaultCellularFormat = 'opus';
  static const double defaultDesktopPlaybackVolume = 1;

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

  /// Saves general device settings. Appearance (including layout and Looks),
  /// Home section order/visibility and setup release markers are targeted-only,
  /// so stale screen snapshots cannot revert newer writes.
  ///
  /// The integration-owned columns
  /// (`updateCheckEnabled`, `useLrclib`, `legacyInstantMixEnabled`, the
  /// Last.fm key and the ListenBrainz connection) are written only when
  /// given, and `SettingsRepository.saveSettings` never gives them: they
  /// belong to the targeted writers ([setIntegrationEnabled],
  /// [updateLastFmApiKey], [updateListenBrainzScrobblingState]) so a stale
  /// screen snapshot cannot revert a switch or a token clear.
  Future<void> saveSettings({
    int? wifiMaxBitRate,
    String? wifiFormat,
    int? cellularMaxBitRate,
    String? cellularFormat,
    required bool cachedPlaybackFirst,
    required bool scrobbleEnabled,
    required bool gaplessEnabled,
    bool fastSeekingEnabled = true,
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
    String? appLocale,
    required bool crossfadeEnabled,
    required int crossfadeDurationSeconds,
    required String crossfadeType,
    bool? updateCheckEnabled,
    required String updateChannel,
    required int syncIntervalMinutes,
    bool backgroundSyncUnmeteredOnly = true,
    bool? useLrclib,
    bool? legacyInstantMixEnabled,
    required String replayGainMode,
    required double replayGainPreamp,
    double? playbackSpeed,
    bool homeRecommendationsAutoAdvance = false,
    bool desktopFocusPlayerModeEnabled = false,
    double desktopPlaybackVolume = defaultDesktopPlaybackVolume,
    double desktopLastAudibleVolume = defaultDesktopPlaybackVolume,
    String? libraryPageOrder,
    String desktopNavbarStyle = 'comfortable',
    bool desktopNavbarAutohide = false,
    bool albumQueueEnabled = true,
    bool matchFlowEnabled = false,
    bool likedQueueEnabled = true,
    String? lastFmApiKey,
    bool? lastFmScrobblingEnabled,
    bool? lastFmSessionConnected,
    bool? listenBrainzScrobblingEnabled,
    bool? listenBrainzTokenValid,
    String? listenBrainzUserName,
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
        fastSeekingEnabled: Value(fastSeekingEnabled),
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
        appLocale: Value(appLocale),
        crossfadeEnabled: Value(crossfadeEnabled),
        crossfadeDurationSeconds: Value(crossfadeDurationSeconds),
        crossfadeType: Value(crossfadeType),
        updateCheckEnabled: updateCheckEnabled == null
            ? const Value.absent()
            : Value(updateCheckEnabled),
        updateChannel: Value(updateChannel),
        syncIntervalMinutes: Value(syncIntervalMinutes),
        backgroundSyncUnmeteredOnly: Value(backgroundSyncUnmeteredOnly),
        useLrclib: useLrclib == null ? const Value.absent() : Value(useLrclib),
        legacyInstantMixEnabled: legacyInstantMixEnabled == null
            ? const Value.absent()
            : Value(legacyInstantMixEnabled),
        replayGainMode: Value(replayGainMode),
        replayGainPreamp: Value(replayGainPreamp),
        playbackSpeed: playbackSpeed == null
            ? const Value.absent()
            : Value(playbackSpeed),
        homeRecommendationsAutoAdvance: Value(homeRecommendationsAutoAdvance),
        desktopFocusPlayerModeEnabled: Value(desktopFocusPlayerModeEnabled),
        desktopPlaybackVolume: Value(desktopPlaybackVolume),
        desktopLastAudibleVolume: Value(desktopLastAudibleVolume),
        libraryPageOrder: Value(libraryPageOrder),
        desktopNavbarStyle: Value(desktopNavbarStyle),
        desktopNavbarAutohide: Value(desktopNavbarAutohide),
        albumQueueEnabled: Value(albumQueueEnabled),
        matchFlowEnabled: Value(matchFlowEnabled),
        likedQueueEnabled: Value(likedQueueEnabled),
        lastFmApiKey: lastFmApiKey == null
            ? const Value.absent()
            : Value(lastFmApiKey),
        lastFmScrobblingEnabled: lastFmScrobblingEnabled == null
            ? const Value.absent()
            : Value(lastFmScrobblingEnabled),
        lastFmSessionConnected: lastFmSessionConnected == null
            ? const Value.absent()
            : Value(lastFmSessionConnected),
        listenBrainzScrobblingEnabled: listenBrainzScrobblingEnabled == null
            ? const Value.absent()
            : Value(listenBrainzScrobblingEnabled),
        listenBrainzTokenValid: listenBrainzTokenValid == null
            ? const Value.absent()
            : Value(listenBrainzTokenValid),
        listenBrainzUserName: listenBrainzUserName == null
            ? const Value.absent()
            : Value(listenBrainzUserName),
        updatedAt: DateTime.now(),
      ),
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

  /// Removes preset libraries and selections without changing current values.
  /// Earlier development databases can retain retired Fine-Tune columns.
  Future<void> deleteAllPresets() => transaction(() async {
    await (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      const AppSettingsTableCompanion(
        playbackPresets: Value('[]'),
        selectedPlaybackPresetId: Value(null),
        appearanceLooks: Value('[]'),
        selectedAppearanceLookId: Value(null),
      ),
    );
    final columns = await customSelect('PRAGMA table_info(app_settings)').get();
    final names = columns.map((row) => row.read<String>('name')).toSet();
    if (names.contains('color_tuning_presets')) {
      await customUpdate(
        "UPDATE app_settings SET color_tuning_presets = '[]' WHERE id = 1",
        updates: {appSettingsTable},
      );
    }
    if (names.contains('selected_color_tuning_preset_id')) {
      await customUpdate(
        'UPDATE app_settings SET selected_color_tuning_preset_id = NULL WHERE id = 1',
        updates: {appSettingsTable},
      );
    }
  });

  /// Resets only the settings the Playback page shows: streaming quality,
  /// scrobbling, gapless/cross-fade, ReplayGain, queue options, the
  /// fullscreen-lyrics switch and the current speed and pitch. Appearance,
  /// Looks, colours, setup highlights, downloads, integrations and saved
  /// presets are left untouched.
  Future<void> resetPlaybackDefaults() async {
    await updatePlaybackAdjustments(
      speed: 1,
      pitchSemitones: 0,
      selectedPresetId: 'none',
    );
    await _writeSettings(
      const AppSettingsTableCompanion(
        wifiMaxBitRate: Value(null),
        wifiFormat: Value(null),
        cellularMaxBitRate: Value(defaultCellularBitRate),
        cellularFormat: Value(defaultCellularFormat),
        cachedPlaybackFirst: Value(false),
        scrobbleEnabled: Value(true),
        gaplessEnabled: Value(true),
        fastSeekingEnabled: Value(true),
        skipSilenceEnabled: Value(false),
        crossfadeEnabled: Value(false),
        crossfadeDurationSeconds: Value(5),
        crossfadeType: Value('normal'),
        replayGainMode: Value('off'),
        replayGainPreamp: Value(0),
        albumQueueEnabled: Value(true),
        likedQueueEnabled: Value(true),
        matchFlowEnabled: Value(false),
      ),
    );
  }

  /// Writes changed setup listening and queue options without a full-row save.
  Future<void> updateSetupListeningPreferences({
    Value<int?> wifiMaxBitRate = const Value.absent(),
    Value<String?> wifiFormat = const Value.absent(),
    Value<int?> cellularMaxBitRate = const Value.absent(),
    Value<String?> cellularFormat = const Value.absent(),
    Value<bool> cachedPlaybackFirst = const Value.absent(),
    Value<bool> scrobbleEnabled = const Value.absent(),
    Value<bool> gaplessEnabled = const Value.absent(),
    Value<bool> crossfadeEnabled = const Value.absent(),
    Value<int> crossfadeDurationSeconds = const Value.absent(),
    Value<String> crossfadeType = const Value.absent(),
    Value<bool> albumQueueEnabled = const Value.absent(),
    Value<bool> likedQueueEnabled = const Value.absent(),
  }) => _writeSettings(
    AppSettingsTableCompanion(
      wifiMaxBitRate: wifiMaxBitRate,
      wifiFormat: wifiFormat,
      cellularMaxBitRate: cellularMaxBitRate,
      cellularFormat: cellularFormat,
      cachedPlaybackFirst: cachedPlaybackFirst,
      scrobbleEnabled: scrobbleEnabled,
      gaplessEnabled: gaplessEnabled,
      crossfadeEnabled: crossfadeEnabled,
      crossfadeDurationSeconds: crossfadeDurationSeconds,
      crossfadeType: crossfadeType,
      albumQueueEnabled: albumQueueEnabled,
      likedQueueEnabled: likedQueueEnabled,
    ),
  );

  /// Clears only per-option setup acknowledgements, for reset and diagnostics.
  Future<void> clearSetupHighlightsSeen() => _writeSettings(
    AppSettingsTableCompanion(setupHighlightsSeen: const Value(null)),
  );

  /// Adds one seen option atomically without overwriting simultaneous options.
  Future<void> markSetupHighlightSeen(String key) => transaction(() async {
    final row = await getSettings();
    final seen = <String>{};
    try {
      final decoded = jsonDecode(row?.setupHighlightsSeen ?? '[]');
      if (decoded is List) seen.addAll(decoded.whereType<String>());
    } on FormatException {
      // An invalid legacy value has no acknowledged options.
    }
    if (!seen.add(key)) return;
    await (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        setupHighlightsSeen: Value(jsonEncode(seen.toList())),
        updatedAt: Value(DateTime.now()),
      ),
    );
  });

  /// Writes only the acknowledged setup release; null clears it.
  ///
  /// Deliberately absent from [saveSettings] to preserve newer targeted writes.
  Future<void> updateSetupHighlightsSeenRelease(String? release) {
    return _writeSettings(
      AppSettingsTableCompanion(setupHighlightsSeenRelease: Value(release)),
    );
  }

  /// Writes only the dismissed Home invitation release; null clears it.
  ///
  /// Deliberately absent from [saveSettings] so onboarding drafts cannot revert it.
  Future<void> updateSetupCardDismissedRelease(String? release) {
    return _writeSettings(
      AppSettingsTableCompanion(setupCardDismissedRelease: Value(release)),
    );
  }

  Stream<int> watchOnboardingVersion() {
    return watchSettings().map((settings) => settings?.onboardingVersion ?? 0);
  }

  Future<void> completeOnboarding(int version) {
    return _writeSettings(
      AppSettingsTableCompanion(onboardingVersion: Value(version)),
    );
  }

  // ---------------------------------------------------------------------------
  // Page visibility helpers
  // ---------------------------------------------------------------------------

  /// Targeted update for show albums page.
  Future<void> updateShowAlbumsPage({required bool enabled}) {
    return _writeSettings(
      AppSettingsTableCompanion(showAlbumsPage: Value(enabled)),
    );
  }

  /// Targeted update for show radio page.
  Future<void> updateShowRadioPage({required bool enabled}) {
    return _writeSettings(
      AppSettingsTableCompanion(showRadioPage: Value(enabled)),
    );
  }

  /// Saves the explicit destination choice without changing other settings.
  Future<void> updatePlaylistCreateOnServer({required bool enabled}) {
    return _writeSettings(
      AppSettingsTableCompanion(playlistCreateOnServer: Value(enabled)),
    );
  }

  /// Targeted update for show playlists page.
  Future<void> updateShowPlaylistsPage({required bool enabled}) {
    return _writeSettings(
      AppSettingsTableCompanion(showPlaylistsPage: Value(enabled)),
    );
  }

  /// Targeted update for show artists page.
  Future<void> updateShowArtistsPage({required bool enabled}) {
    return _writeSettings(
      AppSettingsTableCompanion(showArtistsPage: Value(enabled)),
    );
  }

  /// Targeted update for show liked page.
  Future<void> updateShowLikedPage({required bool enabled}) {
    return _writeSettings(
      AppSettingsTableCompanion(showLikedPage: Value(enabled)),
    );
  }

  // ---------------------------------------------------------------------------
  // Cache budget helpers
  // ---------------------------------------------------------------------------

  static const int defaultRollingCacheBudgetMb = 2048;

  /// Targeted update for rolling cache budget without touching other settings.
  Future<void> updateRollingCacheBudgetMb(int mb) {
    return _writeSettings(
      AppSettingsTableCompanion(rollingCacheBudgetMb: Value(mb)),
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
    return _writeSettings(
      AppSettingsTableCompanion(wifiOnlyDownloads: Value(enabled)),
    );
  }

  /// Targeted update for the auto-download liked content flag.
  Future<void> updateAutoDownloadStarredOnWifi({required bool enabled}) {
    return _writeSettings(
      AppSettingsTableCompanion(autoDownloadStarredOnWifi: Value(enabled)),
    );
  }

  /// Targeted update for the custom permanent-download-folder toggle.
  Future<void> updateCustomDownloadFolderEnabled({required bool enabled}) {
    return _writeSettings(
      AppSettingsTableCompanion(customDownloadFolderEnabled: Value(enabled)),
    );
  }

  /// Targeted update for the custom permanent-download-folder path.
  Future<void> updateCustomDownloadFolderPath(String? path) {
    return _writeSettings(
      AppSettingsTableCompanion(customDownloadFolderPath: Value(path)),
    );
  }

  Future<void> updateCustomDownloadFolderStorageKind(String kind) {
    return _writeSettings(
      AppSettingsTableCompanion(customDownloadFolderStorageKind: Value(kind)),
    );
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
    return _writeSettings(
      AppSettingsTableCompanion(
        downloadQualityMode: Value(mode.name),
        downloadMaxBitRate: bitRate == null
            ? const Value.absent()
            : Value(bitRate),
        downloadFormat: format == null ? const Value.absent() : Value(format),
      ),
    );
  }

  /// Saves the transcode format alone (used by the picker in every mode).
  Future<void> updateDownloadFormat(String format) {
    return _writeSettings(
      AppSettingsTableCompanion(downloadFormat: Value(format)),
    );
  }

  Future<void> updateDownloadQualityPrompted({required bool prompted}) {
    return _writeSettings(
      AppSettingsTableCompanion(downloadQualityPrompted: Value(prompted)),
    );
  }

  Future<void> updateMaxConcurrentDownloads(int value) {
    return _writeSettings(
      AppSettingsTableCompanion(
        maxConcurrentDownloads: Value(sanitizeConcurrentDownloads(value)),
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
    return _writeSettings(
      AppSettingsTableCompanion(downloadsPaused: Value(paused)),
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
    return _writeSettings(AppSettingsTableCompanion(themeMode: Value(mode)));
  }

  /// Targeted update for colour style.
  Future<void> updateColorStyle(String style) {
    return _writeSettings(AppSettingsTableCompanion(colorStyle: Value(style)));
  }

  /// Targeted update for OLED in Auto mode.
  Future<void> updateOledForAuto({required bool enabled}) {
    return _writeSettings(
      AppSettingsTableCompanion(oledForAuto: Value(enabled)),
    );
  }

  /// Targeted update for the Flat area mask.
  Future<void> updateFlatAreas(int bits) async {
    final areas = FlatAreas.fromBits(bits);
    await _writeSettings(
      AppSettingsTableCompanion(flatAreas: Value(areas.bits)),
    );
  }

  /// Writes tuning without touching other settings.
  Future<void> updateColorTuning(ColorTuning tuning) async {
    await getSettings();
    await _writeSettings(
      AppSettingsTableCompanion(
        colorVividness: Value(tuning.vividness),
        surfaceDepthLight: Value(tuning.lightDepth),
        surfaceDepthDark: Value(tuning.darkDepth),
        surfaceTintLight: Value(tuning.lightTint),
        surfaceTintDark: Value(tuning.darkTint),
        controlColor: Value(tuning.controls.name),
      ),
    );
  }

  Future<void> updateAppearanceLooks({
    required String? selectedLookId,
    String? looksJson,
  }) async {
    await getSettings();
    await (update(
      appSettingsTable,
    )..where((t) => t.id.equals(primarySettingsId))).write(
      AppSettingsTableCompanion(
        selectedAppearanceLookId: Value(selectedLookId),
        appearanceLooks: looksJson == null
            ? const Value.absent()
            : Value(looksJson),
      ),
    );
  }

  /// Applies only supplied appearance fields atomically.
  Future<void> applyAppearanceSnapshot(AppearanceSnapshot snapshot) =>
      transaction(() async {
        final current = (await getSettings())!;
        final tuning = ColorTuning(
          vividness: snapshot.colorVividness ?? current.colorVividness,
          lightDepth: snapshot.surfaceDepthLight ?? current.surfaceDepthLight,
          darkDepth: snapshot.surfaceDepthDark ?? current.surfaceDepthDark,
          lightTint: snapshot.surfaceTintLight ?? current.surfaceTintLight,
          darkTint: snapshot.surfaceTintDark ?? current.surfaceTintDark,
          controls: NavisControlColor.parse(
            snapshot.controlColor ?? current.controlColor,
          ),
        );
        await (update(
          appSettingsTable,
        )..where((t) => t.id.equals(primarySettingsId))).write(
          AppSettingsTableCompanion(
            themeMode: snapshot.themeMode == null
                ? const Value.absent()
                : Value(snapshot.themeMode!),
            oledForAuto: snapshot.oledForAuto == null
                ? const Value.absent()
                : Value(snapshot.oledForAuto!),
            colorStyle: snapshot.colorStyle == null
                ? const Value.absent()
                : Value(snapshot.colorStyle!),
            colorSchemeSeed: snapshot.clearColorSchemeSeed
                ? const Value(null)
                : snapshot.colorSchemeSeed == null
                ? const Value.absent()
                : Value(snapshot.colorSchemeSeed),
            dynamicAlbumColorEnabled: snapshot.dynamicAlbumColorEnabled == null
                ? const Value.absent()
                : Value(snapshot.dynamicAlbumColorEnabled!),
            nightScheduleEnabled: snapshot.nightScheduleEnabled == null
                ? const Value.absent()
                : Value(snapshot.nightScheduleEnabled!),
            nightScheduleStartMinutes:
                snapshot.nightScheduleStartMinutes == null
                ? const Value.absent()
                : Value(snapshot.nightScheduleStartMinutes!),
            nightScheduleEndMinutes: snapshot.nightScheduleEndMinutes == null
                ? const Value.absent()
                : Value(snapshot.nightScheduleEndMinutes!),
            albumArtShade: snapshot.albumArtShade == null
                ? const Value.absent()
                : Value(snapshot.albumArtShade!),
            albumArtColoredShade: snapshot.albumArtColoredShade == null
                ? const Value.absent()
                : Value(snapshot.albumArtColoredShade!),
            colorVividness: Value(tuning.vividness),
            surfaceDepthLight: Value(tuning.lightDepth),
            surfaceDepthDark: Value(tuning.darkDepth),
            surfaceTintLight: Value(tuning.lightTint),
            surfaceTintDark: Value(tuning.darkTint),
            controlColor: Value(tuning.controls.name),
            flatSurfaces: snapshot.flatSurfaces == null
                ? const Value.absent()
                : Value(snapshot.flatSurfaces!),
            flatAreas: snapshot.flatAreas == null
                ? const Value.absent()
                : Value(snapshot.flatAreas!),
            cornerStyle: snapshot.cornerStyle == null
                ? const Value.absent()
                : Value(snapshot.cornerStyle!),
            coverArtShape: snapshot.coverArtShape == null
                ? const Value.absent()
                : Value(snapshot.coverArtShape!),
            nowPlayingArtShape: snapshot.nowPlayingArtShape == null
                ? const Value.absent()
                : Value(snapshot.nowPlayingArtShape!),
            artistCardShape: snapshot.artistCardShape == null
                ? const Value.absent()
                : Value(snapshot.artistCardShape!),
            gridArtworkSize: snapshot.gridArtworkSize == null
                ? const Value.absent()
                : Value(snapshot.gridArtworkSize!),
            albumGridDensity: snapshot.clearAlbumGridDensity
                ? const Value(null)
                : snapshot.albumGridDensity == null
                ? const Value.absent()
                : Value(snapshot.albumGridDensity),
            homeDensity: snapshot.density == null
                ? const Value.absent()
                : Value(snapshot.density!),
            artistViewMode: snapshot.artistViewMode == null
                ? const Value.absent()
                : Value(snapshot.artistViewMode!),
            nowPlayingBackground: snapshot.nowPlayingBackground == null
                ? const Value.absent()
                : Value(snapshot.nowPlayingBackground!),
            updatedAt: Value(DateTime.now()),
          ),
        );
      });

  Future<void> updateAlbumArtShade({required bool enabled}) async {
    await _writeSettings(
      AppSettingsTableCompanion(albumArtShade: Value(enabled)),
    );
  }

  Future<void> updateAlbumArtColoredShade({required bool enabled}) async {
    await _writeSettings(
      AppSettingsTableCompanion(albumArtColoredShade: Value(enabled)),
    );
  }

  /// Targeted update for the Flat Surfaces switch.
  Future<void> updateFlatSurfaces({required bool enabled}) {
    return _writeSettings(
      AppSettingsTableCompanion(flatSurfaces: Value(enabled)),
    );
  }

  /// Targeted update for the daily Night schedule.
  Future<void> updateNightSchedule({
    bool? enabled,
    int? startMinutes,
    int? endMinutes,
  }) {
    return _writeSettings(
      AppSettingsTableCompanion(
        nightScheduleEnabled: enabled == null
            ? const Value.absent()
            : Value(enabled),
        nightScheduleStartMinutes: startMinutes == null
            ? const Value.absent()
            : Value(startMinutes.clamp(0, 1439)),
        nightScheduleEndMinutes: endMinutes == null
            ? const Value.absent()
            : Value(endMinutes.clamp(0, 1439)),
      ),
    );
  }

  /// Targeted update for color scheme seed.
  Future<void> updateColorSchemeSeed(int? seed) {
    return _writeSettings(
      AppSettingsTableCompanion(colorSchemeSeed: Value(seed)),
    );
  }

  /// Targeted update for locale override code.
  Future<void> updateAppLocale(String? localeCode) {
    return _writeSettings(
      AppSettingsTableCompanion(appLocale: Value(localeCode)),
    );
  }

  // ---------------------------------------------------------------------------
  // Custom color presets helpers
  // ---------------------------------------------------------------------------

  /// Targeted update for custom color presets (JSON string of int list).
  Future<void> updateCustomColorPresets(String? json) {
    return _writeSettings(
      AppSettingsTableCompanion(customColorPresets: Value(json)),
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
    return _writeSettings(
      AppSettingsTableCompanion(coverArtCacheMaxObjects: Value(maxObjects)),
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
  // Corner style and Art-tinted Now Playing helpers
  // ---------------------------------------------------------------------------

  /// Writes the canonical chrome corner style without changing other settings.
  Future<void> updateCornerStyle(String value) {
    final style = NavisCornerStyle.parse(value);
    return _writeSettings(
      AppSettingsTableCompanion(cornerStyle: Value(style.name)),
    );
  }

  /// Writes the canonical background choice.
  Future<void> updateNowPlayingBackground(String value) {
    final background = NowPlayingBackground.parse(value);
    return _writeSettings(
      AppSettingsTableCompanion(
        nowPlayingBackground: Value(background.storageKey),
      ),
    );
  }

  /// Targeted update for dynamic album-color theming.
  Future<void> updateDynamicAlbumColorEnabled({required bool enabled}) {
    return _writeSettings(
      AppSettingsTableCompanion(dynamicAlbumColorEnabled: Value(enabled)),
    );
  }

  // ---------------------------------------------------------------------------
  // Sync interval helpers
  // ---------------------------------------------------------------------------

  /// Targeted update for sync interval minutes.
  Future<void> updateSyncIntervalMinutes(int minutes) {
    return _writeSettings(
      AppSettingsTableCompanion(syncIntervalMinutes: Value(minutes)),
    );
  }

  /// Targeted update for background sync unmetered-only preference.
  Future<void> updateBackgroundSyncUnmeteredOnly({required bool enabled}) {
    return _writeSettings(
      AppSettingsTableCompanion(backgroundSyncUnmeteredOnly: Value(enabled)),
    );
  }

  // ---------------------------------------------------------------------------
  // Appearance personalization helpers
  // ---------------------------------------------------------------------------

  Future<void> updateGridArtworkSize(String size) async {
    await getSettings();
    await _writeSettings(
      AppSettingsTableCompanion(gridArtworkSize: Value(size)),
    );
  }

  Future<void> updateHomeRecommendationsAutoAdvance({
    required bool enabled,
  }) async {
    await getSettings();
    await _writeSettings(
      AppSettingsTableCompanion(homeRecommendationsAutoAdvance: Value(enabled)),
    );
  }

  /// Targeted update for library cover art shape ('square', 'rounded', 'circle').
  Future<void> updateCoverArtShape(String shape) {
    return _writeSettings(
      AppSettingsTableCompanion(coverArtShape: Value(shape)),
    );
  }

  /// Targeted update for Now Playing art shape ('square', 'rounded', 'circle').
  Future<void> updateNowPlayingArtShape(String shape) {
    return _writeSettings(
      AppSettingsTableCompanion(nowPlayingArtShape: Value(shape)),
    );
  }

  /// Targeted update for artist card shape ('square', 'rounded', 'circle').
  Future<void> updateArtistCardShape(String shape) {
    return _writeSettings(
      AppSettingsTableCompanion(artistCardShape: Value(shape)),
    );
  }

  /// Targeted update for artist view mode ('grid' or 'list').
  Future<void> updateArtistViewMode(String mode) {
    return _writeSettings(
      AppSettingsTableCompanion(artistViewMode: Value(mode)),
    );
  }

  Future<void> updateDensity(NavisDensity density) {
    return _writeSettings(
      AppSettingsTableCompanion(homeDensity: Value(density.storageKey)),
    );
  }

  /// Targeted update for home section order (JSON string list, or null for default).
  Future<void> updateHomeSectionOrder(String? json) {
    return _writeSettings(
      AppSettingsTableCompanion(homeSectionOrder: Value(json)),
    );
  }

  /// Updates hidden Home sections from a JSON string list.
  ///
  /// `null` restores the built-in default hidden set; `[]` hides nothing.
  Future<void> updateHomeSectionsHidden(String? json) {
    return _writeSettings(
      AppSettingsTableCompanion(homeSectionsHidden: Value(json)),
    );
  }

  /// Targeted update for library page order (JSON string list, or null for default).
  Future<void> updateLibraryPageOrder(String? json) {
    return _writeSettings(
      AppSettingsTableCompanion(libraryPageOrder: Value(json)),
    );
  }

  /// Targeted update for desktop navigation sidebar style.
  Future<void> updateDesktopNavbarStyle(String style) {
    return _writeSettings(
      AppSettingsTableCompanion(desktopNavbarStyle: Value(style)),
    );
  }

  /// Targeted update for desktop navigation sidebar autohide.
  // Keep the existing method and callback call contract for callers.
  // ignore: avoid_positional_boolean_parameters
  Future<void> updateDesktopNavbarAutohide(bool enabled) {
    return _writeSettings(
      AppSettingsTableCompanion(desktopNavbarAutohide: Value(enabled)),
    );
  }

  /// Atomically persists the current desktop volume and its unmute target.
  Future<void> updateDesktopPlaybackVolume({
    required double volume,
    required double lastAudibleVolume,
  }) {
    return _writeSettings(
      AppSettingsTableCompanion(
        desktopPlaybackVolume: Value(volume),
        desktopLastAudibleVolume: Value(lastAudibleVolume),
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
    return _writeSettings(
      AppSettingsTableCompanion(lastFullSyncAppBuild: Value(versionBuild)),
    );
  }

  /// Writes only the custom Last.fm API key (null clears it), so saving a key
  /// after a slow validation cannot revert integration switches changed
  /// meanwhile.
  Future<void> updateLastFmApiKey(String? key) =>
      _writeSettings(AppSettingsTableCompanion(lastFmApiKey: Value(key)));

  Future<void> updateListenBrainzScrobblingState({
    bool? enabled,
    bool? tokenValid,
    String? userName,
    bool clearUserName = false,
  }) {
    return _writeSettings(
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
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // External integration policy
  //
  // These columns are deliberately absent from [saveSettings], so a stale
  // full-row save cannot overwrite them. Only these targeted writers change
  // them.
  // ---------------------------------------------------------------------------

  /// Writes the "Online services" master switch and/or the raw disabled-keys
  /// JSON. A null argument leaves that column untouched.
  Future<void> updateIntegrationPolicy({bool? master, String? disabledJson}) {
    return _writeSettings(
      AppSettingsTableCompanion(
        externalIntegrationsEnabled: master == null
            ? const Value.absent()
            : Value(master),
        disabledIntegrations: disabledJson == null
            ? const Value.absent()
            : Value(disabledJson),
      ),
    );
  }

  /// Writes the "Online services" master switch.
  Future<void> setExternalIntegrationsEnabled({required bool enabled}) =>
      updateIntegrationPolicy(master: enabled);

  /// Writes the Same Vibes switch's storage: `true` means Server Mix, which
  /// is Same Vibes switched off.
  Future<void> updateLegacyInstantMixEnabled({required bool enabled}) {
    return _writeSettings(
      AppSettingsTableCompanion(legacyInstantMixEnabled: Value(enabled)),
    );
  }

  Future<void> updateIntegrationsNoticeDismissed({required bool dismissed}) {
    return _writeSettings(
      AppSettingsTableCompanion(integrationsNoticeDismissed: Value(dismissed)),
    );
  }

  /// Switches one integration service or feature on or off.
  ///
  /// The single write path for every integration toggle. A feature stored in
  /// a legacy column writes that column; any other key read-modify-writes the
  /// disabled-keys JSON inside a transaction, so concurrent toggles cannot
  /// lose each other. Throws [ArgumentError] for a key that is neither a
  /// service nor a feature.
  Future<void> setIntegrationEnabled(String key, {required bool enabled}) {
    final feature = IntegrationFeature.tryParse(key);
    if (feature == null && IntegrationService.tryParse(key) == null) {
      throw ArgumentError.value(key, 'key', 'Unknown integration key');
    }
    final column = feature?.legacyColumn;
    if (column != null) {
      final value = column.columnValueFor(featureEnabled: enabled);
      return switch (column) {
        IntegrationLegacyColumn.useLrclib => _writeSettings(
          AppSettingsTableCompanion(useLrclib: Value(value)),
        ),
        IntegrationLegacyColumn.updateCheckEnabled => _writeSettings(
          AppSettingsTableCompanion(updateCheckEnabled: Value(value)),
        ),
        IntegrationLegacyColumn.listenBrainzScrobblingEnabled => _writeSettings(
          AppSettingsTableCompanion(
            listenBrainzScrobblingEnabled: Value(value),
          ),
        ),
        IntegrationLegacyColumn.legacyInstantMixEnabled =>
          updateLegacyInstantMixEnabled(enabled: value),
      };
    }
    return transaction(() async {
      final row = await (select(
        appSettingsTable,
      )..where((t) => t.id.equals(primarySettingsId))).getSingleOrNull();
      final disabled = <String>{
        ...parseDisabledIntegrationKeys(row?.disabledIntegrations),
      };
      if (enabled) {
        disabled.remove(key);
      } else {
        disabled.add(key);
      }
      await updateIntegrationPolicy(
        disabledJson: encodeDisabledIntegrationKeys(disabled),
      );
    });
  }

  Future<void> _writeSettings(AppSettingsTableCompanion values) {
    return (update(appSettingsTable)
          ..where((t) => t.id.equals(primarySettingsId)))
        .write(values.copyWith(updatedAt: Value(DateTime.now())));
  }
}
