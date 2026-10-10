import 'package:flutter/foundation.dart';
import 'package:navis/src/features/settings/domain/flat_areas.dart';
import 'package:navis/src/features/settings/domain/night_schedule.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/theme/navis_corner_style.dart';

double sanitizeDesktopPlaybackVolume(double? value) {
  if (value == null || !value.isFinite) {
    return AppSettingsDao.defaultDesktopPlaybackVolume;
  }
  return value.clamp(0.0, 1.0);
}

double sanitizeDesktopLastAudibleVolume(double? value) {
  final normalized = sanitizeDesktopPlaybackVolume(value);
  if (normalized <= 0.001) {
    return AppSettingsDao.defaultDesktopPlaybackVolume;
  }
  return normalized;
}

@immutable
class AppSettingsModel {
  const new({
    required this.wifiMaxBitRate,
    required this.wifiFormat,
    required this.cellularMaxBitRate,
    required this.cellularFormat,
    this.cachedPlaybackFirst = false,
    required this.scrobbleEnabled,
    required this.gaplessEnabled,
    required this.skipSilenceEnabled,
    required this.showAlbumsPage,
    required this.showRadioPage,
    required this.showPlaylistsPage,
    required this.showArtistsPage,
    required this.showLikedPage,

    required this.wifiOnlyDownloads,
    required this.autoDownloadStarredOnWifi,
    required this.customDownloadFolderEnabled,
    required this.customDownloadFolderPath,
    required this.themeMode,
    this.colorStyle = 'neutral',
    this.oledForAuto = false,
    this.nightScheduleEnabled = false,
    this.nightScheduleStartMinutes = NightSchedule.defaultStartMinutes,
    this.nightScheduleEndMinutes = NightSchedule.defaultEndMinutes,
    this.flatSurfaces = false,
    this.flatAreas = const FlatAreas(),
    this.albumArtShade = false,
    this.albumArtColoredShade = false,
    required this.colorSchemeSeed,
    required this.appLocale,
    required this.crossfadeEnabled,
    required this.crossfadeDurationSeconds,
    required this.crossfadeType,
    this.nowPlayingBackground = NowPlayingBackground.tinted,
    this.cornerStyle = NavisCornerStyle.rounded,
    required this.dynamicAlbumColorEnabled,
    required this.updateCheckEnabled,
    required this.updateChannel,
    required this.syncIntervalMinutes,
    this.backgroundSyncUnmeteredOnly = true,
    required this.useLrclib,
    required this.legacyInstantMixEnabled,
    required this.replayGainMode,
    required this.replayGainPreamp,
    required this.playbackSpeed,
    this.playbackPitchSemitones = 0,
    this.lockPitchToSpeed = false,
    this.playbackPresets = const [],
    this.selectedPlaybackPresetId,
    required this.albumGridDensity,
    this.gridArtworkSize = GridArtworkSize.auto,
    this.homeRecommendationsAutoAdvance = false,
    required this.coverArtShape,
    required this.nowPlayingArtShape,
    required this.artistCardShape,
    required this.artistViewMode,
    this.desktopFocusPlayerModeEnabled = false,
    this.desktopPlaybackVolume = AppSettingsDao.defaultDesktopPlaybackVolume,
    this.desktopLastAudibleVolume = AppSettingsDao.defaultDesktopPlaybackVolume,
    this.homeDensity = NavisDensity.comfortable,
    required this.homeSectionOrder,
    required this.homeSectionsHidden,
    required this.libraryPageOrder,
    this.desktopNavbarStyle = 'comfortable',
    this.desktopNavbarAutohide = false,
    this.albumQueueEnabled = true,
    this.matchFlowEnabled = false,
    this.likedQueueEnabled = true,
    this.lastFmApiKey,
    this.lastFmScrobblingEnabled = false,
    this.lastFmSessionConnected = false,
    this.listenBrainzScrobblingEnabled = false,
    this.listenBrainzTokenValid = false,
    this.listenBrainzUserName,
    this.externalIntegrationsEnabled = true,
    this.disabledIntegrations = '[]',
    this.integrationsNoticeDismissed = false,
    this.setupHighlightsSeen = const <String>{},
    this.setupHighlightsSeenRelease,
    this.setupCardDismissedRelease,
  });

  const new defaults()
    : wifiMaxBitRate = null,
      wifiFormat = null,
      cellularMaxBitRate = AppSettingsDao.defaultCellularBitRate,
      cellularFormat = AppSettingsDao.defaultCellularFormat,
      cachedPlaybackFirst = false,
      scrobbleEnabled = true,
      gaplessEnabled = true,
      skipSilenceEnabled = false,
      showAlbumsPage = true,
      showRadioPage = true,
      showPlaylistsPage = true,
      showArtistsPage = true,
      showLikedPage = true,

      wifiOnlyDownloads = true,
      autoDownloadStarredOnWifi = false,
      customDownloadFolderEnabled = false,
      customDownloadFolderPath = null,
      themeMode = 'dark',
      colorStyle = 'neutral',
      oledForAuto = false,
      nightScheduleEnabled = false,
      nightScheduleStartMinutes = NightSchedule.defaultStartMinutes,
      nightScheduleEndMinutes = NightSchedule.defaultEndMinutes,
      flatSurfaces = false,
      flatAreas = const FlatAreas(),
      albumArtShade = false,
      albumArtColoredShade = false,
      colorSchemeSeed = null,
      appLocale = null,
      crossfadeEnabled = false,
      crossfadeDurationSeconds = 5,
      crossfadeType = 'normal',
      nowPlayingBackground = NowPlayingBackground.tinted,
      cornerStyle = NavisCornerStyle.rounded,
      dynamicAlbumColorEnabled = false,
      updateCheckEnabled = true,
      updateChannel = 'stable',
      syncIntervalMinutes = 60,
      backgroundSyncUnmeteredOnly = true,
      useLrclib = true,
      legacyInstantMixEnabled = false,
      replayGainMode = 'off',
      replayGainPreamp = 0.0,
      playbackSpeed = 1.0,
      playbackPitchSemitones = 0,
      lockPitchToSpeed = false,
      playbackPresets = const [],
      selectedPlaybackPresetId = null,
      albumGridDensity = null,
      gridArtworkSize = GridArtworkSize.auto,
      homeRecommendationsAutoAdvance = false,
      coverArtShape = 'square',
      nowPlayingArtShape = 'rounded',
      artistCardShape = 'circle',
      artistViewMode = 'grid',
      desktopFocusPlayerModeEnabled = false,
      desktopPlaybackVolume = AppSettingsDao.defaultDesktopPlaybackVolume,
      desktopLastAudibleVolume = AppSettingsDao.defaultDesktopPlaybackVolume,
      homeDensity = NavisDensity.comfortable,
      homeSectionOrder = null,
      homeSectionsHidden = null,
      libraryPageOrder = null,
      desktopNavbarStyle = 'comfortable',
      desktopNavbarAutohide = false,
      albumQueueEnabled = true,
      matchFlowEnabled = false,
      likedQueueEnabled = true,
      lastFmApiKey = null,
      lastFmScrobblingEnabled = false,
      lastFmSessionConnected = false,
      listenBrainzScrobblingEnabled = false,
      listenBrainzTokenValid = false,
      listenBrainzUserName = null,
      externalIntegrationsEnabled = true,
      disabledIntegrations = '[]',
      integrationsNoticeDismissed = false,
      setupHighlightsSeen = const <String>{},
      setupHighlightsSeenRelease = null,
      setupCardDismissedRelease = null;

  final int? wifiMaxBitRate;
  final String? wifiFormat;
  final int? cellularMaxBitRate;
  final String? cellularFormat;
  final bool cachedPlaybackFirst;
  final bool scrobbleEnabled;
  final bool gaplessEnabled;
  // Compatibility-only persisted field retained to keep schema upgrades safe.
  // Runtime playback behavior intentionally does not consume this setting.
  final bool skipSilenceEnabled;
  final bool showAlbumsPage;
  final bool showRadioPage;
  final bool showPlaylistsPage;
  final bool showArtistsPage;
  final bool showLikedPage;

  final bool wifiOnlyDownloads;
  final bool autoDownloadStarredOnWifi;
  final bool customDownloadFolderEnabled;
  final String? customDownloadFolderPath;
  final String themeMode;
  final String colorStyle;
  final bool oledForAuto;
  final bool nightScheduleEnabled;
  final int nightScheduleStartMinutes;
  final int nightScheduleEndMinutes;
  final bool flatSurfaces;
  final FlatAreas flatAreas;
  final bool albumArtShade;
  final bool albumArtColoredShade;
  final int? colorSchemeSeed;
  final String? appLocale;
  final bool crossfadeEnabled;
  final int crossfadeDurationSeconds;
  final String crossfadeType;
  final NowPlayingBackground nowPlayingBackground;
  final NavisCornerStyle cornerStyle;

  final bool dynamicAlbumColorEnabled;
  final bool updateCheckEnabled;
  final String updateChannel;
  final int syncIntervalMinutes;

  /// When true, automatic/background library sync waits for an unmetered
  /// network. Metered connections may still run a hard probe and interactive
  /// hydration.
  final bool backgroundSyncUnmeteredOnly;
  final bool useLrclib;
  final bool legacyInstantMixEnabled;

  /// ReplayGain mode: 'off', 'track', or 'album'.
  final String replayGainMode;

  /// ReplayGain pre-amp adjustment in dB (-6.0 to +6.0).
  final double replayGainPreamp;

  /// Playback speed multiplier.
  final double playbackSpeed;
  final double playbackPitchSemitones;
  final bool lockPitchToSpeed;
  final List<PlaybackPreset> playbackPresets;
  final String? selectedPlaybackPresetId;

  /// Album grid column count override. Null = auto-compute from screen width.
  final int? albumGridDensity;

  final GridArtworkSize gridArtworkSize;
  final bool homeRecommendationsAutoAdvance;

  /// Shape preset for cover art in library/carousel cards: 'square', 'rounded', or 'circle'.
  final String coverArtShape;

  /// Shape preset for the Now Playing album art: 'square', 'rounded', or 'circle'.
  final String nowPlayingArtShape;

  /// Shape preset for artist cards: 'square', 'rounded', or 'circle'.
  final String artistCardShape;

  /// Artist view layout: 'list' or 'grid'.
  final String artistViewMode;

  /// When true on desktop runtime, the app launches in compact focus mode.
  final bool desktopFocusPlayerModeEnabled;

  /// Navis playback volume restored by desktop clients.
  final double desktopPlaybackVolume;

  /// Last non-muted desktop volume restored by the mute toggle.
  final double desktopLastAudibleVolume;

  /// Density now covers Home and lists; the legacy storage name is retained.
  final NavisDensity homeDensity;

  NavisDensity get density => homeDensity;

  /// Ordered list of home section IDs, or null for default order.
  final List<String>? homeSectionOrder;

  /// List of hidden home section IDs, or null meaning none hidden.
  final List<String>? homeSectionsHidden;

  /// Ordered list of library page IDs, or null for default order.
  final List<String>? libraryPageOrder;

  /// Desktop navigation sidebar style: 'comfortable', 'compact', or 'icons'.
  final String desktopNavbarStyle;

  /// When true on desktop, the navigation sidebar autohides.
  final bool desktopNavbarAutohide;

  /// When true, tapping a track in an album queues the full album and starts
  /// at the selected track instead of queuing only that track.
  final bool albumQueueEnabled;

  /// When true, user queue actions expand configured Match Flows.
  final bool matchFlowEnabled;

  /// When true (and [albumQueueEnabled] is also true), tapping a track on the
  /// Liked page queues all liked songs and starts at the selected track.
  final bool likedQueueEnabled;

  /// User-provided Last.fm API key. Null when not configured.
  /// Ignored at runtime if a build-time key (NAVIS_LASTFM_API_KEY) is bundled.
  final String? lastFmApiKey;

  /// Deprecated compatibility flag. Last.fm scrobble dispatch was removed.
  final bool lastFmScrobblingEnabled;

  /// Deprecated compatibility flag. Last.fm session auth was removed.
  final bool lastFmSessionConnected;

  /// Enables ListenBrainz scrobble dispatch.
  final bool listenBrainzScrobblingEnabled;

  /// Whether the stored ListenBrainz token has validated successfully.
  final bool listenBrainzTokenValid;

  /// MusicBrainz username returned by ListenBrainz token validation.
  final String? listenBrainzUserName;

  /// The "Online services" master switch. Read-only here: the full-row save
  /// never writes it; the integration-policy DAO writers do.
  final bool externalIntegrationsEnabled;

  /// Raw JSON list of disabled service and feature keys without a column of
  /// their own. Kept raw so selectors compare cheaply; parse it with
  /// `parseDisabledIntegrationKeys`. Read-only here, like
  /// [externalIntegrationsEnabled].
  final String disabledIntegrations;

  /// Whether the one-time Integrations notice on Home was dismissed.
  final bool integrationsNoticeDismissed;

  /// Setup highlight storage keys already shown, written only via targeted writes.
  final Set<String> setupHighlightsSeen;

  /// Latest setup highlight release acknowledged by Finish (or first-run Skip).
  ///
  /// Written only through targeted writers, never by a full settings save.
  final String? setupHighlightsSeenRelease;

  /// Latest setup highlight release whose Home card was dismissed.
  ///
  /// Dismissal does not acknowledge the setup highlights themselves.
  final String? setupCardDismissedRelease;

  AppSettingsModel copyWith({
    int? wifiMaxBitRate,
    String? wifiFormat,
    int? cellularMaxBitRate,
    String? cellularFormat,
    bool? cachedPlaybackFirst,
    bool? scrobbleEnabled,
    bool? gaplessEnabled,
    bool? skipSilenceEnabled,
    bool? showAlbumsPage,
    bool? showRadioPage,
    bool? showPlaylistsPage,
    bool? showArtistsPage,
    bool? showLikedPage,

    bool? wifiOnlyDownloads,
    bool? autoDownloadStarredOnWifi,
    bool? customDownloadFolderEnabled,
    String? customDownloadFolderPath,
    String? themeMode,
    String? colorStyle,
    bool? oledForAuto,
    bool? nightScheduleEnabled,
    int? nightScheduleStartMinutes,
    int? nightScheduleEndMinutes,
    bool? flatSurfaces,
    FlatAreas? flatAreas,
    bool? albumArtShade,
    bool? albumArtColoredShade,
    int? colorSchemeSeed,
    String? appLocale,
    bool? crossfadeEnabled,
    int? crossfadeDurationSeconds,
    String? crossfadeType,
    NowPlayingBackground? nowPlayingBackground,
    NavisCornerStyle? cornerStyle,
    bool? dynamicAlbumColorEnabled,
    bool? updateCheckEnabled,
    String? updateChannel,
    int? syncIntervalMinutes,
    bool? backgroundSyncUnmeteredOnly,
    bool? useLrclib,
    bool? legacyInstantMixEnabled,
    String? replayGainMode,
    double? replayGainPreamp,
    double? playbackSpeed,
    double? playbackPitchSemitones,
    bool? lockPitchToSpeed,
    List<PlaybackPreset>? playbackPresets,
    String? selectedPlaybackPresetId,
    bool clearSelectedPlaybackPresetId = false,
    int? albumGridDensity,
    GridArtworkSize? gridArtworkSize,
    bool? homeRecommendationsAutoAdvance,
    String? coverArtShape,
    String? nowPlayingArtShape,
    String? artistCardShape,
    String? artistViewMode,
    bool? desktopFocusPlayerModeEnabled,
    double? desktopPlaybackVolume,
    double? desktopLastAudibleVolume,
    NavisDensity? homeDensity,
    NavisDensity? density,
    List<String>? homeSectionOrder,
    List<String>? homeSectionsHidden,
    List<String>? libraryPageOrder,
    String? desktopNavbarStyle,
    bool? desktopNavbarAutohide,
    bool? albumQueueEnabled,
    bool? matchFlowEnabled,
    bool? likedQueueEnabled,
    String? lastFmApiKey,
    bool? lastFmScrobblingEnabled,
    bool? lastFmSessionConnected,
    bool? listenBrainzScrobblingEnabled,
    bool? listenBrainzTokenValid,
    String? listenBrainzUserName,
    bool? externalIntegrationsEnabled,
    String? disabledIntegrations,
    bool? integrationsNoticeDismissed,
    Set<String>? setupHighlightsSeen,
    String? setupHighlightsSeenRelease,
    String? setupCardDismissedRelease,
    bool clearSetupHighlightsSeenRelease = false,
    bool clearSetupCardDismissedRelease = false,
    bool clearWifiBitRate = false,
    bool clearWifiFormat = false,
    bool clearCellularBitRate = false,
    bool clearCellularFormat = false,
    bool clearColorSchemeSeed = false,
    bool clearAppLocale = false,
    bool clearCustomDownloadFolderPath = false,
    bool clearAlbumGridDensity = false,
    bool clearHomeSectionOrder = false,
    bool clearHomeSectionsHidden = false,
    bool clearLibraryPageOrder = false,
    bool clearLastFmApiKey = false,
    bool clearListenBrainzUserName = false,
  }) {
    return AppSettingsModel(
      wifiMaxBitRate: clearWifiBitRate
          ? null
          : wifiMaxBitRate ?? this.wifiMaxBitRate,
      wifiFormat: clearWifiFormat ? null : wifiFormat ?? this.wifiFormat,
      cellularMaxBitRate: clearCellularBitRate
          ? null
          : cellularMaxBitRate ?? this.cellularMaxBitRate,
      cellularFormat: clearCellularFormat
          ? null
          : cellularFormat ?? this.cellularFormat,
      cachedPlaybackFirst: cachedPlaybackFirst ?? this.cachedPlaybackFirst,
      scrobbleEnabled: scrobbleEnabled ?? this.scrobbleEnabled,
      gaplessEnabled: gaplessEnabled ?? this.gaplessEnabled,
      skipSilenceEnabled: skipSilenceEnabled ?? this.skipSilenceEnabled,
      showAlbumsPage: showAlbumsPage ?? this.showAlbumsPage,
      showRadioPage: showRadioPage ?? this.showRadioPage,
      showPlaylistsPage: showPlaylistsPage ?? this.showPlaylistsPage,
      showArtistsPage: showArtistsPage ?? this.showArtistsPage,
      showLikedPage: showLikedPage ?? this.showLikedPage,

      wifiOnlyDownloads: wifiOnlyDownloads ?? this.wifiOnlyDownloads,
      autoDownloadStarredOnWifi:
          autoDownloadStarredOnWifi ?? this.autoDownloadStarredOnWifi,
      customDownloadFolderEnabled:
          customDownloadFolderEnabled ?? this.customDownloadFolderEnabled,
      customDownloadFolderPath: clearCustomDownloadFolderPath
          ? null
          : customDownloadFolderPath ?? this.customDownloadFolderPath,
      themeMode: themeMode ?? this.themeMode,
      colorStyle: colorStyle ?? this.colorStyle,
      oledForAuto: oledForAuto ?? this.oledForAuto,
      nightScheduleEnabled: nightScheduleEnabled ?? this.nightScheduleEnabled,
      nightScheduleStartMinutes:
          nightScheduleStartMinutes ?? this.nightScheduleStartMinutes,
      nightScheduleEndMinutes:
          nightScheduleEndMinutes ?? this.nightScheduleEndMinutes,
      flatSurfaces: flatSurfaces ?? this.flatSurfaces,
      flatAreas: flatAreas ?? this.flatAreas,
      albumArtShade: albumArtShade ?? this.albumArtShade,
      albumArtColoredShade: albumArtColoredShade ?? this.albumArtColoredShade,
      colorSchemeSeed: clearColorSchemeSeed
          ? null
          : colorSchemeSeed ?? this.colorSchemeSeed,
      appLocale: clearAppLocale ? null : appLocale ?? this.appLocale,
      crossfadeEnabled: crossfadeEnabled ?? this.crossfadeEnabled,
      crossfadeDurationSeconds:
          crossfadeDurationSeconds ?? this.crossfadeDurationSeconds,
      crossfadeType: crossfadeType ?? this.crossfadeType,
      nowPlayingBackground: nowPlayingBackground ?? this.nowPlayingBackground,
      cornerStyle: cornerStyle ?? this.cornerStyle,
      dynamicAlbumColorEnabled:
          dynamicAlbumColorEnabled ?? this.dynamicAlbumColorEnabled,
      updateCheckEnabled: updateCheckEnabled ?? this.updateCheckEnabled,
      updateChannel: updateChannel ?? this.updateChannel,
      syncIntervalMinutes: syncIntervalMinutes ?? this.syncIntervalMinutes,
      backgroundSyncUnmeteredOnly:
          backgroundSyncUnmeteredOnly ?? this.backgroundSyncUnmeteredOnly,
      useLrclib: useLrclib ?? this.useLrclib,
      legacyInstantMixEnabled:
          legacyInstantMixEnabled ?? this.legacyInstantMixEnabled,
      replayGainMode: replayGainMode ?? this.replayGainMode,
      replayGainPreamp: replayGainPreamp ?? this.replayGainPreamp,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      playbackPitchSemitones:
          playbackPitchSemitones ?? this.playbackPitchSemitones,
      lockPitchToSpeed: lockPitchToSpeed ?? this.lockPitchToSpeed,
      playbackPresets: playbackPresets ?? this.playbackPresets,
      selectedPlaybackPresetId: clearSelectedPlaybackPresetId
          ? null
          : selectedPlaybackPresetId ?? this.selectedPlaybackPresetId,
      albumGridDensity: clearAlbumGridDensity
          ? null
          : albumGridDensity ?? this.albumGridDensity,
      gridArtworkSize: gridArtworkSize ?? this.gridArtworkSize,
      homeRecommendationsAutoAdvance:
          homeRecommendationsAutoAdvance ?? this.homeRecommendationsAutoAdvance,
      coverArtShape: coverArtShape ?? this.coverArtShape,
      nowPlayingArtShape: nowPlayingArtShape ?? this.nowPlayingArtShape,
      artistCardShape: artistCardShape ?? this.artistCardShape,
      artistViewMode: artistViewMode ?? this.artistViewMode,
      desktopFocusPlayerModeEnabled:
          desktopFocusPlayerModeEnabled ?? this.desktopFocusPlayerModeEnabled,
      desktopPlaybackVolume:
          desktopPlaybackVolume ?? this.desktopPlaybackVolume,
      desktopLastAudibleVolume:
          desktopLastAudibleVolume ?? this.desktopLastAudibleVolume,
      homeDensity: density ?? homeDensity ?? this.homeDensity,
      homeSectionOrder: clearHomeSectionOrder
          ? null
          : homeSectionOrder ?? this.homeSectionOrder,
      homeSectionsHidden: clearHomeSectionsHidden
          ? null
          : homeSectionsHidden ?? this.homeSectionsHidden,
      libraryPageOrder: clearLibraryPageOrder
          ? null
          : libraryPageOrder ?? this.libraryPageOrder,
      desktopNavbarStyle: desktopNavbarStyle ?? this.desktopNavbarStyle,
      desktopNavbarAutohide:
          desktopNavbarAutohide ?? this.desktopNavbarAutohide,
      albumQueueEnabled: albumQueueEnabled ?? this.albumQueueEnabled,
      matchFlowEnabled: matchFlowEnabled ?? this.matchFlowEnabled,
      likedQueueEnabled: likedQueueEnabled ?? this.likedQueueEnabled,
      lastFmApiKey: clearLastFmApiKey
          ? null
          : lastFmApiKey ?? this.lastFmApiKey,
      lastFmScrobblingEnabled:
          lastFmScrobblingEnabled ?? this.lastFmScrobblingEnabled,
      lastFmSessionConnected:
          lastFmSessionConnected ?? this.lastFmSessionConnected,
      listenBrainzScrobblingEnabled:
          listenBrainzScrobblingEnabled ?? this.listenBrainzScrobblingEnabled,
      listenBrainzTokenValid:
          listenBrainzTokenValid ?? this.listenBrainzTokenValid,
      listenBrainzUserName: clearListenBrainzUserName
          ? null
          : listenBrainzUserName ?? this.listenBrainzUserName,
      externalIntegrationsEnabled:
          externalIntegrationsEnabled ?? this.externalIntegrationsEnabled,
      disabledIntegrations: disabledIntegrations ?? this.disabledIntegrations,
      integrationsNoticeDismissed:
          integrationsNoticeDismissed ?? this.integrationsNoticeDismissed,
      setupHighlightsSeen: setupHighlightsSeen ?? this.setupHighlightsSeen,
      setupHighlightsSeenRelease: clearSetupHighlightsSeenRelease
          ? null
          : setupHighlightsSeenRelease ?? this.setupHighlightsSeenRelease,
      setupCardDismissedRelease: clearSetupCardDismissedRelease
          ? null
          : setupCardDismissedRelease ?? this.setupCardDismissedRelease,
    );
  }
}
