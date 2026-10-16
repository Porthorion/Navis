import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/flat_areas.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/theme/color_adjustment.dart';
import 'package:navis/src/features/settings/domain/appearance_presets.dart';
import 'package:navis/src/theme/navis_corner_style.dart';

class SettingsRepository {
  new(this._dao);

  final AppSettingsDao _dao;

  Stream<AppSettingsModel> watchSettings() {
    return _dao.watchSettings().asyncMap((row) async {
      return _mapOrDefault(row);
    });
  }

  Future<AppSettingsModel> getSettings() async {
    final row = await _dao.getSettings();
    return _mapOrDefault(row);
  }

  Future<void> setPlaylistCreateOnServer({required bool enabled}) =>
      _dao.updatePlaylistCreateOnServer(enabled: enabled);

  Future<void> saveSettings(AppSettingsModel settings) async {
    // skipSilenceEnabled is persisted for compatibility with older schema
    // versions but is currently not applied at runtime playback level.
    await _dao.saveSettings(
      wifiMaxBitRate: settings.wifiMaxBitRate,
      wifiFormat: settings.wifiFormat,
      cellularMaxBitRate: settings.cellularMaxBitRate,
      cellularFormat: settings.cellularFormat,
      cachedPlaybackFirst: settings.cachedPlaybackFirst,
      scrobbleEnabled: settings.scrobbleEnabled,
      gaplessEnabled: settings.gaplessEnabled,
      skipSilenceEnabled: settings.skipSilenceEnabled,
      showAlbumsPage: settings.showAlbumsPage,
      showRadioPage: settings.showRadioPage,
      showPlaylistsPage: settings.showPlaylistsPage,
      showArtistsPage: settings.showArtistsPage,
      showLikedPage: settings.showLikedPage,

      wifiOnlyDownloads: settings.wifiOnlyDownloads,
      autoDownloadStarredOnWifi: settings.autoDownloadStarredOnWifi,
      customDownloadFolderEnabled: settings.customDownloadFolderEnabled,
      customDownloadFolderPath: settings.customDownloadFolderPath,
      themeMode: settings.themeMode,
      colorStyle: settings.colorStyle,
      oledForAuto: settings.oledForAuto,
      nightScheduleEnabled: settings.nightScheduleEnabled,
      nightScheduleStartMinutes: settings.nightScheduleStartMinutes,
      nightScheduleEndMinutes: settings.nightScheduleEndMinutes,
      flatSurfaces: settings.flatSurfaces,
      flatAreas: settings.flatAreas.bits,
      colorVividness: settings.colorVividness,
      surfaceDepthLight: settings.surfaceDepthLight,
      surfaceDepthDark: settings.surfaceDepthDark,
      surfaceTintLight: settings.surfaceTintLight,
      surfaceTintDark: settings.surfaceTintDark,
      controlColor: settings.controlColor,
      albumArtShade: settings.albumArtShade,
      albumArtColoredShade: settings.albumArtColoredShade,
      colorSchemeSeed: settings.colorSchemeSeed,
      appLocale: settings.appLocale,
      crossfadeEnabled: settings.crossfadeEnabled,
      crossfadeDurationSeconds: settings.crossfadeDurationSeconds,
      crossfadeType: settings.crossfadeType,
      nowPlayingBackground: settings.nowPlayingBackground.storageKey,
      cornerStyle: settings.cornerStyle.name,
      dynamicAlbumColorEnabled: settings.dynamicAlbumColorEnabled,
      updateChannel: settings.updateChannel,
      syncIntervalMinutes: settings.syncIntervalMinutes,
      backgroundSyncUnmeteredOnly: settings.backgroundSyncUnmeteredOnly,
      replayGainMode: settings.replayGainMode,
      replayGainPreamp: settings.replayGainPreamp,
      // Playback adjustments have a dedicated writer; stale screen snapshots
      // must not overwrite the current sound or selected preset.
      albumGridDensity: settings.albumGridDensity,
      gridArtworkSize: settings.gridArtworkSize.name,
      homeRecommendationsAutoAdvance: settings.homeRecommendationsAutoAdvance,
      coverArtShape: settings.coverArtShape,
      nowPlayingArtShape: settings.nowPlayingArtShape,
      artistCardShape: settings.artistCardShape,
      artistViewMode: settings.artistViewMode,
      desktopFocusPlayerModeEnabled: settings.desktopFocusPlayerModeEnabled,
      desktopPlaybackVolume: sanitizeDesktopPlaybackVolume(
        settings.desktopPlaybackVolume,
      ),
      desktopLastAudibleVolume: sanitizeDesktopLastAudibleVolume(
        settings.desktopLastAudibleVolume,
      ),
      homeDensity: settings.homeDensity.storageKey,
      homeSectionOrder: _encodeStringList(settings.homeSectionOrder),
      homeSectionsHidden: _encodeStringList(settings.homeSectionsHidden),
      libraryPageOrder: _encodeStringList(settings.libraryPageOrder),
      desktopNavbarStyle: settings.desktopNavbarStyle,
      desktopNavbarAutohide: settings.desktopNavbarAutohide,
      albumQueueEnabled: settings.albumQueueEnabled,
      matchFlowEnabled: settings.matchFlowEnabled,
      likedQueueEnabled: settings.likedQueueEnabled,
    );
    // Setup release markers are targeted-only, so a stale onboarding draft
    // cannot overwrite acknowledgements or card dismissals.
    // Integration-owned columns (the policy columns, the legacy feature
    // columns, the Last.fm key and the ListenBrainz connection) are not part
    // of the full-row save; see AppSettingsDao.saveSettings.
  }

  /// Saves only setup choices changed from the snapshot captured at entry.
  Future<void> saveOnboardingChanges(
    AppSettingsModel initial,
    AppSettingsModel draft,
  ) async {
    if (draft.themeMode != initial.themeMode) {
      await _dao.updateThemeMode(draft.themeMode);
    }
    if (draft.colorStyle != initial.colorStyle) {
      await _dao.updateColorStyle(draft.colorStyle);
    }
    if (draft.oledForAuto != initial.oledForAuto) {
      await _dao.updateOledForAuto(enabled: draft.oledForAuto);
    }
    if (draft.flatSurfaces != initial.flatSurfaces) {
      await _dao.updateFlatSurfaces(enabled: draft.flatSurfaces);
    }
    if (draft.colorVividness != initial.colorVividness ||
        draft.surfaceDepthLight != initial.surfaceDepthLight ||
        draft.surfaceDepthDark != initial.surfaceDepthDark ||
        draft.surfaceTintLight != initial.surfaceTintLight ||
        draft.surfaceTintDark != initial.surfaceTintDark ||
        draft.controlColor != initial.controlColor) {
      final current = await getSettings();
      await _dao.updateColorTuning(
        ColorTuning(
          lightTint: draft.surfaceTintLight != initial.surfaceTintLight
              ? draft.surfaceTintLight
              : current.surfaceTintLight,
          darkTint: draft.surfaceTintDark != initial.surfaceTintDark
              ? draft.surfaceTintDark
              : current.surfaceTintDark,
          controls: NavisControlColor.parse(
            draft.controlColor != initial.controlColor
                ? draft.controlColor
                : current.controlColor,
          ),
          vividness: draft.colorVividness != initial.colorVividness
              ? draft.colorVividness
              : current.colorVividness,
          lightDepth: draft.surfaceDepthLight != initial.surfaceDepthLight
              ? draft.surfaceDepthLight
              : current.surfaceDepthLight,
          darkDepth: draft.surfaceDepthDark != initial.surfaceDepthDark
              ? draft.surfaceDepthDark
              : current.surfaceDepthDark,
        ),
      );
    }
    if (draft.flatAreas != initial.flatAreas) {
      await _dao.updateFlatAreas(draft.flatAreas.bits);
    }
    if (draft.albumArtShade != initial.albumArtShade) {
      await _dao.updateAlbumArtShade(enabled: draft.albumArtShade);
    }
    if (draft.albumArtColoredShade != initial.albumArtColoredShade) {
      await _dao.updateAlbumArtColoredShade(
        enabled: draft.albumArtColoredShade,
      );
    }
    if (draft.cornerStyle != initial.cornerStyle) {
      await _dao.updateCornerStyle(draft.cornerStyle.name);
    }
    if (draft.nowPlayingBackground != initial.nowPlayingBackground) {
      await _dao.updateNowPlayingBackground(
        draft.nowPlayingBackground.storageKey,
      );
    }
    if (draft.colorSchemeSeed != initial.colorSchemeSeed) {
      await _dao.updateColorSchemeSeed(draft.colorSchemeSeed);
    }
    if (draft.wifiOnlyDownloads != initial.wifiOnlyDownloads) {
      await _dao.updateWifiOnlyDownloads(enabled: draft.wifiOnlyDownloads);
    }
    if (draft.density != initial.density) {
      await _dao.updateDensity(draft.density);
    }
    if (draft.nightScheduleEnabled != initial.nightScheduleEnabled ||
        draft.nightScheduleStartMinutes != initial.nightScheduleStartMinutes ||
        draft.nightScheduleEndMinutes != initial.nightScheduleEndMinutes) {
      await _dao.updateNightSchedule(
        enabled: draft.nightScheduleEnabled != initial.nightScheduleEnabled
            ? draft.nightScheduleEnabled
            : null,
        startMinutes:
            draft.nightScheduleStartMinutes != initial.nightScheduleStartMinutes
            ? draft.nightScheduleStartMinutes
            : null,
        endMinutes:
            draft.nightScheduleEndMinutes != initial.nightScheduleEndMinutes
            ? draft.nightScheduleEndMinutes
            : null,
      );
    }
    await _dao.updateSetupListeningPreferences(
      wifiMaxBitRate: draft.wifiMaxBitRate == initial.wifiMaxBitRate
          ? const Value.absent()
          : Value(draft.wifiMaxBitRate),
      wifiFormat: draft.wifiFormat == initial.wifiFormat
          ? const Value.absent()
          : Value(draft.wifiFormat),
      cellularMaxBitRate: draft.cellularMaxBitRate == initial.cellularMaxBitRate
          ? const Value.absent()
          : Value(draft.cellularMaxBitRate),
      cellularFormat: draft.cellularFormat == initial.cellularFormat
          ? const Value.absent()
          : Value(draft.cellularFormat),
      cachedPlaybackFirst:
          draft.cachedPlaybackFirst == initial.cachedPlaybackFirst
          ? const Value.absent()
          : Value(draft.cachedPlaybackFirst),
      scrobbleEnabled: draft.scrobbleEnabled == initial.scrobbleEnabled
          ? const Value.absent()
          : Value(draft.scrobbleEnabled),
      gaplessEnabled: draft.gaplessEnabled == initial.gaplessEnabled
          ? const Value.absent()
          : Value(draft.gaplessEnabled),
      crossfadeEnabled: draft.crossfadeEnabled == initial.crossfadeEnabled
          ? const Value.absent()
          : Value(draft.crossfadeEnabled),
      crossfadeDurationSeconds:
          draft.crossfadeDurationSeconds == initial.crossfadeDurationSeconds
          ? const Value.absent()
          : Value(draft.crossfadeDurationSeconds),
      crossfadeType: draft.crossfadeType == initial.crossfadeType
          ? const Value.absent()
          : Value(draft.crossfadeType),
      albumQueueEnabled: draft.albumQueueEnabled == initial.albumQueueEnabled
          ? const Value.absent()
          : Value(draft.albumQueueEnabled),
      likedQueueEnabled: draft.likedQueueEnabled == initial.likedQueueEnabled
          ? const Value.absent()
          : Value(draft.likedQueueEnabled),
    );
  }

  /// Writes only the custom Last.fm API key; null clears it. The full-row
  /// [saveSettings] leaves the key alone.
  Future<void> updateLastFmApiKey(String? key) => _dao.updateLastFmApiKey(key);

  Future<void> savePlaybackAdjustments({
    required PlaybackAdjustments values,
    required String? selectedPresetId,
    List<PlaybackPreset>? presets,
  }) => _dao.updatePlaybackAdjustments(
    speed: values.speed,
    pitchSemitones: values.pitchSemitones,
    lockPitchToSpeed: values.lockPitchToSpeed,
    selectedPresetId: selectedPresetId,
    presetsJson: presets == null
        ? null
        : jsonEncode(presets.map((p) => p.toJson()).toList()),
  );

  List<PlaybackPreset> _decodePlaybackPresets(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final presets = <PlaybackPreset>[];
      for (final item in decoded) {
        final preset = PlaybackPreset.fromJson(item);
        if (preset != null &&
            !presets.any(
              (p) =>
                  p.id == preset.id ||
                  p.name.toLowerCase() == preset.name.toLowerCase(),
            )) {
          presets.add(preset);
        }
      }
      return List.unmodifiable(presets);
    } on FormatException {
      return const [];
    }
  }

  Future<void> resetDefaults() => _dao.resetDefaults();

  /// Switches one integration service or feature; see
  /// [AppSettingsDao.setIntegrationEnabled].
  Future<void> setIntegrationEnabled(String key, {required bool enabled}) =>
      _dao.setIntegrationEnabled(key, enabled: enabled);

  /// Writes the "Online services" master switch.
  Future<void> setExternalIntegrationsEnabled({required bool enabled}) =>
      _dao.setExternalIntegrationsEnabled(enabled: enabled);

  /// Records whether the one-time 1.5.0 Integrations note on Home was seen.
  Future<void> updateIntegrationsNoticeDismissed({required bool dismissed}) =>
      _dao.updateIntegrationsNoticeDismissed(dismissed: dismissed);

  /// Acknowledges one setup option through an atomic, targeted write.
  Future<void> markSetupHighlightSeen(String key) =>
      _dao.markSetupHighlightSeen(key);

  /// Records the acknowledged setup release; null clears it.
  Future<void> updateSetupHighlightsSeenRelease(String? release) =>
      _dao.updateSetupHighlightsSeenRelease(release);

  /// Records the dismissed setup invitation release; null clears it.
  Future<void> updateSetupCardDismissedRelease(String? release) =>
      _dao.updateSetupCardDismissedRelease(release);

  /// Records the outcome of a ListenBrainz token check without a full-row
  /// save, so a slow validation cannot overwrite switches changed meanwhile.
  /// A null [scrobblingEnabled] leaves the scrobbling switch as it is.
  Future<void> updateListenBrainzConnection({
    required bool tokenValid,
    bool? scrobblingEnabled,
    String? userName,
  }) => _dao.updateListenBrainzScrobblingState(
    enabled: scrobblingEnabled,
    tokenValid: tokenValid,
    userName: userName,
    clearUserName: !tokenValid,
  );

  Future<void> saveDesktopPlaybackVolume({
    required double volume,
    required double lastAudibleVolume,
  }) {
    return _dao.updateDesktopPlaybackVolume(
      volume: sanitizeDesktopPlaybackVolume(volume),
      lastAudibleVolume: sanitizeDesktopLastAudibleVolume(lastAudibleVolume),
    );
  }

  AppSettingsModel _mapOrDefault(AppSettingsTableData? row) {
    if (row == null) {
      return const AppSettingsModel.defaults();
    }
    return AppSettingsModel(
      wifiMaxBitRate: row.wifiMaxBitRate,
      wifiFormat: row.wifiFormat,
      cellularMaxBitRate: row.cellularMaxBitRate,
      cellularFormat: row.cellularFormat,
      cachedPlaybackFirst: row.cachedPlaybackFirst,
      scrobbleEnabled: row.scrobbleEnabled,
      gaplessEnabled: row.gaplessEnabled,
      skipSilenceEnabled: row.skipSilenceEnabled,
      showAlbumsPage: row.showAlbumsPage,
      showRadioPage: row.showRadioPage,
      showPlaylistsPage: row.showPlaylistsPage,
      playlistCreateOnServer: row.playlistCreateOnServer,
      showArtistsPage: row.showArtistsPage,
      showLikedPage: row.showLikedPage,

      wifiOnlyDownloads: row.wifiOnlyDownloads,
      autoDownloadStarredOnWifi: row.autoDownloadStarredOnWifi,
      customDownloadFolderEnabled: row.customDownloadFolderEnabled,
      customDownloadFolderPath: row.customDownloadFolderPath,
      themeMode: row.themeMode,
      colorStyle: row.colorStyle,
      oledForAuto: row.oledForAuto,
      nightScheduleEnabled: row.nightScheduleEnabled,
      nightScheduleStartMinutes: row.nightScheduleStartMinutes,
      nightScheduleEndMinutes: row.nightScheduleEndMinutes,
      flatSurfaces: row.flatSurfaces,
      flatAreas: FlatAreas.fromBits(row.flatAreas),
      colorVividness: row.colorVividness,
      surfaceDepthLight: row.surfaceDepthLight,
      surfaceDepthDark: row.surfaceDepthDark,
      surfaceTintLight: row.surfaceTintLight,
      surfaceTintDark: row.surfaceTintDark,
      controlColor: row.controlColor,
      appearanceLooks: decodeAppearanceLooks(row.appearanceLooks),
      selectedAppearanceLookId: row.selectedAppearanceLookId,
      customColorPresets: decodeAccentSeeds(row.customColorPresets),
      albumArtShade: row.albumArtShade,
      albumArtColoredShade: row.albumArtColoredShade,
      colorSchemeSeed: row.colorSchemeSeed,
      appLocale: row.appLocale,
      crossfadeEnabled: row.crossfadeEnabled,
      crossfadeDurationSeconds: row.crossfadeDurationSeconds,
      crossfadeType: row.crossfadeType,
      nowPlayingBackground: NowPlayingBackground.parse(
        row.nowPlayingBackground,
      ),
      cornerStyle: NavisCornerStyle.parse(row.cornerStyle),
      dynamicAlbumColorEnabled: row.dynamicAlbumColorEnabled,
      updateCheckEnabled: row.updateCheckEnabled,
      updateChannel: row.updateChannel,
      syncIntervalMinutes: row.syncIntervalMinutes,
      backgroundSyncUnmeteredOnly: row.backgroundSyncUnmeteredOnly,
      useLrclib: row.useLrclib,
      legacyInstantMixEnabled: row.legacyInstantMixEnabled,
      replayGainMode: row.replayGainMode,
      replayGainPreamp: row.replayGainPreamp,
      playbackSpeed: row.playbackSpeed,
      playbackPitchSemitones: row.playbackPitchSemitones,
      lockPitchToSpeed: row.lockPitchToSpeed,
      playbackPresets: _decodePlaybackPresets(row.playbackPresets),
      selectedPlaybackPresetId: row.selectedPlaybackPresetId,
      albumGridDensity: row.albumGridDensity,
      gridArtworkSize: GridArtworkSize.parse(row.gridArtworkSize),
      homeRecommendationsAutoAdvance: row.homeRecommendationsAutoAdvance,
      coverArtShape: row.coverArtShape,
      nowPlayingArtShape: row.nowPlayingArtShape,
      artistCardShape: row.artistCardShape,
      artistViewMode: row.artistViewMode,
      desktopFocusPlayerModeEnabled: row.desktopFocusPlayerModeEnabled,
      desktopPlaybackVolume: sanitizeDesktopPlaybackVolume(
        row.desktopPlaybackVolume,
      ),
      desktopLastAudibleVolume: sanitizeDesktopLastAudibleVolume(
        row.desktopLastAudibleVolume,
      ),
      homeDensity: NavisDensity.parse(row.homeDensity),
      homeSectionOrder: _decodeStringList(row.homeSectionOrder),
      homeSectionsHidden: _decodeStringList(row.homeSectionsHidden),
      libraryPageOrder: _decodeStringList(row.libraryPageOrder),
      desktopNavbarStyle: row.desktopNavbarStyle,
      desktopNavbarAutohide: row.desktopNavbarAutohide,
      albumQueueEnabled: row.albumQueueEnabled,
      matchFlowEnabled: row.matchFlowEnabled,
      likedQueueEnabled: row.likedQueueEnabled,
      lastFmApiKey: row.lastFmApiKey,
      lastFmScrobblingEnabled: row.lastFmScrobblingEnabled,
      lastFmSessionConnected: row.lastFmSessionConnected,
      listenBrainzScrobblingEnabled: row.listenBrainzScrobblingEnabled,
      listenBrainzTokenValid: row.listenBrainzTokenValid,
      listenBrainzUserName: row.listenBrainzUserName,
      externalIntegrationsEnabled: row.externalIntegrationsEnabled,
      disabledIntegrations: row.disabledIntegrations,
      integrationsNoticeDismissed: row.integrationsNoticeDismissed,
      setupHighlightsSeen: _decodeStringSet(row.setupHighlightsSeen),
      setupHighlightsSeenRelease: row.setupHighlightsSeenRelease,
      setupCardDismissedRelease: row.setupCardDismissedRelease,
    );
  }

  Set<String> _decodeStringSet(String? raw) {
    try {
      final decoded = jsonDecode(raw ?? '[]');
      return decoded is List
          ? Set.unmodifiable(decoded.whereType<String>())
          : const <String>{};
    } on FormatException {
      return const <String>{};
    }
  }

  String? _encodeStringList(List<String>? values) {
    if (values == null || values.isEmpty) {
      return null;
    }
    return jsonEncode(values);
  }

  List<String>? _decodeStringList(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return null;
      }
      return decoded.cast<String>().toList(growable: false);
    } on FormatException {
      return null;
    }
  }
}
