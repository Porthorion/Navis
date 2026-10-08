import 'dart:convert';

import 'package:navis/src/features/player/domain/playback_adjustments.dart';

import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/routing/content_layout.dart';

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
      colorSchemeSeed: settings.colorSchemeSeed,
      appLocale: settings.appLocale,
      crossfadeEnabled: settings.crossfadeEnabled,
      crossfadeDurationSeconds: settings.crossfadeDurationSeconds,
      crossfadeType: settings.crossfadeType,
      artTintedNowPlaying: settings.artTintedNowPlaying,
      dynamicAlbumColorEnabled: settings.dynamicAlbumColorEnabled,
      updateChannel: settings.updateChannel,
      audioMuseServerUrl: settings.audioMuseServerUrl,
      audioMuseApiKey: settings.audioMuseApiKey,
      audioMuseEnabled: settings.audioMuseEnabled,
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
      homeDensity: settings.homeDensity,
      homeSectionOrder: _encodeStringList(settings.homeSectionOrder),
      homeSectionsHidden: _encodeStringList(settings.homeSectionsHidden),
      libraryPageOrder: _encodeStringList(settings.libraryPageOrder),
      desktopNavbarStyle: settings.desktopNavbarStyle,
      desktopNavbarAutohide: settings.desktopNavbarAutohide,
      albumQueueEnabled: settings.albumQueueEnabled,
      matchFlowEnabled: settings.matchFlowEnabled,
      likedQueueEnabled: settings.likedQueueEnabled,
      customVoyageServers: null,
    );
    // Integration-owned columns (the policy columns, the legacy feature
    // columns, the Last.fm key and the ListenBrainz connection) are not part
    // of the full-row save; see AppSettingsDao.saveSettings.
    await _dao.saveGroupListeningSettings(
      groupListeningEnabled: false,
      voyageServerUrl: null,
      voyageDisplayName: null,
      voyageDeviceLabel: null,
      voyageAutoFollowHost: AppSettingsDao.defaultVoyageAutoFollowHost,
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

  /// Records whether the one-time 1.4.3 Integrations note on Home was seen.
  Future<void> updateIntegrationsNoticeDismissed({required bool dismissed}) =>
      _dao.updateIntegrationsNoticeDismissed(dismissed: dismissed);

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
      colorSchemeSeed: row.colorSchemeSeed,
      appLocale: row.appLocale,
      crossfadeEnabled: row.crossfadeEnabled,
      crossfadeDurationSeconds: row.crossfadeDurationSeconds,
      crossfadeType: row.crossfadeType,
      artTintedNowPlaying: row.artTintedNowPlaying,
      dynamicAlbumColorEnabled: row.dynamicAlbumColorEnabled,
      updateCheckEnabled: row.updateCheckEnabled,
      updateChannel: row.updateChannel,
      audioMuseServerUrl: row.audioMuseServerUrl,
      audioMuseApiKey: row.audioMuseApiKey,
      audioMuseEnabled: row.audioMuseEnabled,
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
      homeDensity: row.homeDensity,
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
      customVoyageServers: const <CustomVoyageServer>[],
      groupListeningEnabled: false,
      voyageServerUrl: null,
      voyageDisplayName: null,
      voyageDeviceLabel: null,
      voyageAutoFollowHost: AppSettingsDao.defaultVoyageAutoFollowHost,
    );
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
