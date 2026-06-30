import 'package:flutter/foundation.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';

@immutable
class CustomVoyageServer {
  const CustomVoyageServer({
    required this.label,
    required this.url,
  });

  final String label;
  final String url;

  Map<String, Object> toJson() => <String, Object>{
    'label': label,
    'url': url,
  };

  static CustomVoyageServer? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final label = raw['label']?.toString().trim() ?? '';
    final url = raw['url']?.toString().trim() ?? '';
    if (url.isEmpty) {
      return null;
    }
    return CustomVoyageServer(label: label.isEmpty ? url : label, url: url);
  }
}

@immutable
class AppSettingsModel {
  const AppSettingsModel({
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
    required this.equalizerEnabled,
    required this.equalizerBandGains,
    required this.loudnessEnabled,
    required this.loudnessTargetGainDb,
    required this.wifiOnlyDownloads,
    required this.autoDownloadStarredOnWifi,
    required this.customDownloadFolderEnabled,
    required this.customDownloadFolderPath,
    required this.themeMode,
    required this.colorSchemeSeed,
    required this.appLocale,
    required this.crossfadeEnabled,
    required this.crossfadeDurationSeconds,
    required this.crossfadeType,
    required this.artTintedNowPlaying,
    required this.dynamicAlbumColorEnabled,
    required this.updateCheckEnabled,
    required this.updateChannel,
    required this.audioMuseServerUrl,
    required this.audioMuseApiKey,
    required this.audioMuseEnabled,
    required this.syncIntervalMinutes,
    required this.useLrclib,
    required this.legacyInstantMixEnabled,
    required this.replayGainMode,
    required this.replayGainPreamp,
    required this.playbackSpeed,
    required this.albumGridDensity,
    required this.coverArtShape,
    required this.nowPlayingArtShape,
    required this.artistCardShape,
    required this.artistViewMode,
    this.desktopFocusPlayerModeEnabled = false,
    this.homeDensity = 'comfortable',
    required this.homeSectionOrder,
    required this.homeSectionsHidden,
    required this.libraryPageOrder,
    this.desktopNavbarStyle = 'comfortable',
    this.desktopNavbarAutohide = false,
    this.albumQueueEnabled = false,
    this.matchFlowEnabled = false,
    this.likedQueueEnabled = false,
    this.lastFmApiKey,
    this.lastFmScrobblingEnabled = false,
    this.lastFmSessionConnected = false,
    this.listenBrainzScrobblingEnabled = false,
    this.listenBrainzTokenValid = false,
    this.listenBrainzUserName,
    this.customVoyageServers = const <CustomVoyageServer>[],
    this.groupListeningEnabled = false,
    this.voyageServerUrl,
    this.voyageDisplayName,
    this.voyageDeviceLabel,
    this.voyageAutoFollowHost = true,
  });

  const AppSettingsModel.defaults()
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
      equalizerEnabled = false,
      equalizerBandGains = const <double>[],
      loudnessEnabled = false,
      loudnessTargetGainDb = 0,
      wifiOnlyDownloads = true,
      autoDownloadStarredOnWifi = false,
      customDownloadFolderEnabled = false,
      customDownloadFolderPath = null,
      themeMode = 'dark',
      colorSchemeSeed = null,
      appLocale = null,
      crossfadeEnabled = false,
      crossfadeDurationSeconds = 5,
      crossfadeType = 'normal',
      artTintedNowPlaying = true,
      dynamicAlbumColorEnabled = false,
      updateCheckEnabled = true,
      updateChannel = 'stable',
      audioMuseServerUrl = null,
      audioMuseApiKey = null,
      audioMuseEnabled = false,
      syncIntervalMinutes = 60,
      useLrclib = true,
      legacyInstantMixEnabled = false,
      replayGainMode = 'off',
      replayGainPreamp = 0.0,
      playbackSpeed = 1.0,
      albumGridDensity = null,
      coverArtShape = 'square',
      nowPlayingArtShape = 'rounded',
      artistCardShape = 'circle',
      artistViewMode = 'grid',
      desktopFocusPlayerModeEnabled = false,
      homeDensity = 'comfortable',
      homeSectionOrder = null,
      homeSectionsHidden = null,
      libraryPageOrder = null,
      desktopNavbarStyle = 'comfortable',
      desktopNavbarAutohide = false,
      albumQueueEnabled = false,
      matchFlowEnabled = false,
      likedQueueEnabled = false,
      lastFmApiKey = null,
      lastFmScrobblingEnabled = false,
      lastFmSessionConnected = false,
      listenBrainzScrobblingEnabled = false,
      listenBrainzTokenValid = false,
      listenBrainzUserName = null,
      customVoyageServers = const <CustomVoyageServer>[],
      groupListeningEnabled = false,
      voyageServerUrl = null,
      voyageDisplayName = null,
      voyageDeviceLabel = null,
      voyageAutoFollowHost = true;

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
  final bool equalizerEnabled;
  final List<double> equalizerBandGains;
  final bool loudnessEnabled;
  final double loudnessTargetGainDb;
  final bool wifiOnlyDownloads;
  final bool autoDownloadStarredOnWifi;
  final bool customDownloadFolderEnabled;
  final String? customDownloadFolderPath;
  final String themeMode;
  final int? colorSchemeSeed;
  final String? appLocale;
  final bool crossfadeEnabled;
  final int crossfadeDurationSeconds;
  final String crossfadeType;
  final bool artTintedNowPlaying;
  final bool dynamicAlbumColorEnabled;
  final bool updateCheckEnabled;
  final String updateChannel;
  final String? audioMuseServerUrl;
  final String? audioMuseApiKey;
  final bool audioMuseEnabled;
  final int syncIntervalMinutes;
  final bool useLrclib;
  final bool legacyInstantMixEnabled;

  /// ReplayGain mode: 'off', 'track', or 'album'.
  final String replayGainMode;

  /// ReplayGain pre-amp adjustment in dB (-6.0 to +6.0).
  final double replayGainPreamp;

  /// Playback speed multiplier (0.5–2.0).
  final double playbackSpeed;

  /// Album grid column count override. Null = auto-compute from screen width.
  final int? albumGridDensity;

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

  /// Home layout density: 'comfortable' or 'compact'.
  final String homeDensity;

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

  /// Legacy retired Listen Together data retained for schema compatibility.
  /// Runtime settings always expose this as empty.
  final List<CustomVoyageServer> customVoyageServers;

  /// Legacy retired Listen Together flag. Runtime settings always expose false.
  final bool groupListeningEnabled;

  /// Legacy retired Voyage base URL. Runtime settings always expose null.
  final String? voyageServerUrl;

  /// Legacy retired display name. Runtime settings always expose null.
  final String? voyageDisplayName;

  /// Legacy retired device label. Runtime settings always expose null.
  final String? voyageDeviceLabel;

  /// Legacy retired follow-host setting. Runtime settings expose the default.
  final bool voyageAutoFollowHost;

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
    bool? equalizerEnabled,
    List<double>? equalizerBandGains,
    bool? loudnessEnabled,
    double? loudnessTargetGainDb,
    bool? wifiOnlyDownloads,
    bool? autoDownloadStarredOnWifi,
    bool? customDownloadFolderEnabled,
    String? customDownloadFolderPath,
    String? themeMode,
    int? colorSchemeSeed,
    String? appLocale,
    bool? crossfadeEnabled,
    int? crossfadeDurationSeconds,
    String? crossfadeType,
    bool? artTintedNowPlaying,
    bool? dynamicAlbumColorEnabled,
    bool? updateCheckEnabled,
    String? updateChannel,
    String? audioMuseServerUrl,
    String? audioMuseApiKey,
    bool? audioMuseEnabled,
    int? syncIntervalMinutes,
    bool? useLrclib,
    bool? legacyInstantMixEnabled,
    String? replayGainMode,
    double? replayGainPreamp,
    double? playbackSpeed,
    int? albumGridDensity,
    String? coverArtShape,
    String? nowPlayingArtShape,
    String? artistCardShape,
    String? artistViewMode,
    bool? desktopFocusPlayerModeEnabled,
    String? homeDensity,
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
    List<CustomVoyageServer>? customVoyageServers,
    bool? groupListeningEnabled,
    String? voyageServerUrl,
    String? voyageDisplayName,
    String? voyageDeviceLabel,
    bool? voyageAutoFollowHost,
    bool clearWifiBitRate = false,
    bool clearWifiFormat = false,
    bool clearCellularBitRate = false,
    bool clearCellularFormat = false,
    bool clearColorSchemeSeed = false,
    bool clearAppLocale = false,
    bool clearCustomDownloadFolderPath = false,
    bool clearAudioMuseServerUrl = false,
    bool clearAudioMuseApiKey = false,
    bool clearAlbumGridDensity = false,
    bool clearHomeSectionOrder = false,
    bool clearHomeSectionsHidden = false,
    bool clearLibraryPageOrder = false,
    bool clearLastFmApiKey = false,
    bool clearListenBrainzUserName = false,
    bool clearVoyageServerUrl = false,
    bool clearVoyageDisplayName = false,
    bool clearVoyageDeviceLabel = false,
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
      equalizerEnabled: equalizerEnabled ?? this.equalizerEnabled,
      equalizerBandGains:
          equalizerBandGains ?? List<double>.from(this.equalizerBandGains),
      loudnessEnabled: loudnessEnabled ?? this.loudnessEnabled,
      loudnessTargetGainDb: loudnessTargetGainDb ?? this.loudnessTargetGainDb,
      wifiOnlyDownloads: wifiOnlyDownloads ?? this.wifiOnlyDownloads,
      autoDownloadStarredOnWifi:
          autoDownloadStarredOnWifi ?? this.autoDownloadStarredOnWifi,
      customDownloadFolderEnabled:
          customDownloadFolderEnabled ?? this.customDownloadFolderEnabled,
      customDownloadFolderPath: clearCustomDownloadFolderPath
          ? null
          : customDownloadFolderPath ?? this.customDownloadFolderPath,
      themeMode: themeMode ?? this.themeMode,
      colorSchemeSeed: clearColorSchemeSeed
          ? null
          : colorSchemeSeed ?? this.colorSchemeSeed,
      appLocale: clearAppLocale ? null : appLocale ?? this.appLocale,
      crossfadeEnabled: crossfadeEnabled ?? this.crossfadeEnabled,
      crossfadeDurationSeconds:
          crossfadeDurationSeconds ?? this.crossfadeDurationSeconds,
      crossfadeType: crossfadeType ?? this.crossfadeType,
      artTintedNowPlaying: artTintedNowPlaying ?? this.artTintedNowPlaying,
      dynamicAlbumColorEnabled:
          dynamicAlbumColorEnabled ?? this.dynamicAlbumColorEnabled,
      updateCheckEnabled: updateCheckEnabled ?? this.updateCheckEnabled,
      updateChannel: updateChannel ?? this.updateChannel,
      audioMuseServerUrl: clearAudioMuseServerUrl
          ? null
          : audioMuseServerUrl ?? this.audioMuseServerUrl,
      audioMuseApiKey: clearAudioMuseApiKey
          ? null
          : audioMuseApiKey ?? this.audioMuseApiKey,
      audioMuseEnabled: audioMuseEnabled ?? this.audioMuseEnabled,
      syncIntervalMinutes: syncIntervalMinutes ?? this.syncIntervalMinutes,
      useLrclib: useLrclib ?? this.useLrclib,
      legacyInstantMixEnabled:
          legacyInstantMixEnabled ?? this.legacyInstantMixEnabled,
      replayGainMode: replayGainMode ?? this.replayGainMode,
      replayGainPreamp: replayGainPreamp ?? this.replayGainPreamp,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      albumGridDensity: clearAlbumGridDensity
          ? null
          : albumGridDensity ?? this.albumGridDensity,
      coverArtShape: coverArtShape ?? this.coverArtShape,
      nowPlayingArtShape: nowPlayingArtShape ?? this.nowPlayingArtShape,
      artistCardShape: artistCardShape ?? this.artistCardShape,
      artistViewMode: artistViewMode ?? this.artistViewMode,
      desktopFocusPlayerModeEnabled:
          desktopFocusPlayerModeEnabled ?? this.desktopFocusPlayerModeEnabled,
      homeDensity: homeDensity ?? this.homeDensity,
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
      customVoyageServers:
          customVoyageServers ??
          List<CustomVoyageServer>.from(this.customVoyageServers),
      groupListeningEnabled:
          groupListeningEnabled ?? this.groupListeningEnabled,
      voyageServerUrl: clearVoyageServerUrl
          ? null
          : voyageServerUrl ?? this.voyageServerUrl,
      voyageDisplayName: clearVoyageDisplayName
          ? null
          : voyageDisplayName ?? this.voyageDisplayName,
      voyageDeviceLabel: clearVoyageDeviceLabel
          ? null
          : voyageDeviceLabel ?? this.voyageDeviceLabel,
      voyageAutoFollowHost: voyageAutoFollowHost ?? this.voyageAutoFollowHost,
    );
  }
}
