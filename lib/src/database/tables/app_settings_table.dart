import 'package:drift/drift.dart';

class AppSettingsTable extends Table {
  @override
  String get tableName => 'app_settings';

  IntColumn get id => integer()();

  IntColumn get wifiMaxBitRate => integer().nullable()();

  TextColumn get wifiFormat => text().nullable()();

  IntColumn get cellularMaxBitRate => integer().nullable()();

  TextColumn get cellularFormat => text().nullable()();

  /// When true, any complete cached audio file is preferred before streaming
  /// the active quality profile. Default false keeps playback settings-first.
  BoolColumn get cachedPlaybackFirst =>
      boolean().withDefault(const Constant(false))();

  BoolColumn get scrobbleEnabled =>
      boolean().withDefault(const Constant(true))();

  BoolColumn get gaplessEnabled =>
      boolean().withDefault(const Constant(true))();

  BoolColumn get skipSilenceEnabled =>
      boolean().withDefault(const Constant(false))();

  BoolColumn get showRadioPage => boolean().withDefault(const Constant(true))();

  BoolColumn get showPlaylistsPage =>
      boolean().withDefault(const Constant(true))();

  BoolColumn get showArtistsPage =>
      boolean().withDefault(const Constant(true))();

  BoolColumn get showLikedPage => boolean().withDefault(const Constant(true))();

  BoolColumn get equalizerEnabled =>
      boolean().withDefault(const Constant(false))();

  TextColumn get equalizerBandGains => text().nullable()();

  BoolColumn get loudnessEnabled =>
      boolean().withDefault(const Constant(false))();

  RealColumn get loudnessTargetGainDb => real().nullable()();

  /// Rolling cache budget in megabytes. Default 2048 (2 GB).
  IntColumn get rollingCacheBudgetMb =>
      integer().withDefault(const Constant(2048))();

  /// When true, downloads only proceed on Wi-Fi / Ethernet.
  BoolColumn get wifiOnlyDownloads =>
      boolean().withDefault(const Constant(false))();

  /// When true, liked albums and songs enqueue for permanent download on Wi-Fi.
  BoolColumn get autoDownloadStarredOnWifi =>
      boolean().withDefault(const Constant(false))();

  /// When true, permanently-downloaded tracks are written into a user-selected
  /// custom folder instead of the default app-managed support directory.
  BoolColumn get customDownloadFolderEnabled =>
      boolean().withDefault(const Constant(false))();

  /// Absolute path to the user-selected permanent-download folder.
  TextColumn get customDownloadFolderPath => text().nullable()();

  /// Theme mode: 'light', 'dark', 'oled', or 'system'. Defaults to 'dark'.
  TextColumn get themeMode => text().withDefault(const Constant('dark'))();

  /// Seed color for the app's ColorScheme. Null = dynamic / default blue.
  IntColumn get colorSchemeSeed => integer().nullable()();

  /// JSON-encoded list of custom color presets (ARGB32 ints).
  TextColumn get customColorPresets => text().nullable()();

  /// Locale override code (e.g. 'en'). Null means follow system locale.
  TextColumn get appLocale => text().nullable()();

  /// Cross-fade between tracks in the queue.
  BoolColumn get crossfadeEnabled =>
      boolean().withDefault(const Constant(false))();

  /// Cross-fade duration in seconds (1–12). Default 5.
  IntColumn get crossfadeDurationSeconds =>
      integer().withDefault(const Constant(5))();

  /// Cross-fade type: 'normal' (always) or 'smart' (different albums only).
  TextColumn get crossfadeType =>
      text().withDefault(const Constant('normal'))();

  /// Max number of cover art images to keep in the disk cache. Default 5000.
  IntColumn get coverArtCacheMaxObjects =>
      integer().withDefault(const Constant(5000))();

  /// When true, the Now Playing background is tinted with album art colors.
  BoolColumn get artTintedNowPlaying =>
      boolean().withDefault(const Constant(true))();

  /// When true, app accent color follows the currently playing album art.
  BoolColumn get dynamicAlbumColorEnabled =>
      boolean().withDefault(const Constant(false))();

  /// Whether to automatically check for updates on launch. Default true.
  BoolColumn get updateCheckEnabled =>
      boolean().withDefault(const Constant(true))();

  /// Update channel: 'stable' (default) or 'beta' (pre-releases included).
  TextColumn get updateChannel =>
      text().withDefault(const Constant('stable'))();

  /// AudioMuse AI server URL. Null when not configured.
  TextColumn get audioMuseServerUrl => text().nullable()();

  /// AudioMuse API key. Null when not required or not configured.
  TextColumn get audioMuseApiKey => text().nullable()();

  /// Whether AudioMuse AI integration is enabled. Default false.
  BoolColumn get audioMuseEnabled =>
      boolean().withDefault(const Constant(false))();

  /// Automatic background sync interval in minutes.
  /// 0 = manual only (disabled). Default 60 (1 hour).
  IntColumn get syncIntervalMinutes =>
      integer().withDefault(const Constant(60))();

  /// Whether LRCLIB fallback is used when server lyrics are unavailable.
  BoolColumn get useLrclib => boolean().withDefault(const Constant(true))();

  /// When true, use legacy local-only Instant Mix instead of Last.fm Same Vibes.
  BoolColumn get legacyInstantMixEnabled =>
      boolean().withDefault(const Constant(false))();

  /// ReplayGain mode: 'off', 'track', or 'album'. Default 'off'.
  TextColumn get replayGainMode => text().withDefault(const Constant('off'))();

  /// ReplayGain pre-amp adjustment in dB (-6.0 to +6.0). Default 0.
  RealColumn get replayGainPreamp => real().withDefault(const Constant(0))();

  /// Playback speed multiplier (0.5–2.0). Default 1.0.
  RealColumn get playbackSpeed => real().withDefault(const Constant(1))();

  /// Album grid column count override. Null = auto (computed from width).
  /// Valid explicit values: 1–4.
  IntColumn get albumGridDensity => integer().nullable()();

  /// Border radius (logical px) for cover art in library cards, carousels, etc.
  /// 0 = square, 24 = very rounded. Default 12.
  RealColumn get coverArtBorderRadius =>
      real().withDefault(const Constant(12))();

  /// Border radius (logical px) for the Now Playing album art. Default 16.
  RealColumn get nowPlayingArtBorderRadius =>
      real().withDefault(const Constant(16))();

  /// Cover art shape preset: 'square' or 'rounded'. Default 'square'.
  TextColumn get coverArtShape =>
      text().withDefault(const Constant('square'))();

  /// Now Playing art shape preset: 'square', 'rounded', or 'circle'. Default 'rounded'.
  TextColumn get nowPlayingArtShape =>
      text().withDefault(const Constant('rounded'))();

  /// Artist card shape preset: 'square', 'rounded', or 'circle'. Default 'circle'.
  TextColumn get artistCardShape =>
      text().withDefault(const Constant('circle'))();

  /// Artist view layout: 'list' or 'grid'. Default 'grid'.
  TextColumn get artistViewMode => text().withDefault(const Constant('grid'))();

  /// When true on desktop runtime, the app restores Focus Player Mode on launch.
  BoolColumn get desktopFocusPlayerModeEnabled =>
      boolean().withDefault(const Constant(false))();

  /// Home section density: 'comfortable' or 'compact'. Default 'comfortable'.
  TextColumn get homeDensity =>
      text().withDefault(const Constant('comfortable'))();

  /// JSON-encoded ordered list of home section IDs (e.g. ["recently_added",…]).
  /// Null = default order.
  TextColumn get homeSectionOrder => text().nullable()();

  /// JSON-encoded list of hidden home section IDs. Null = none hidden.
  TextColumn get homeSectionsHidden => text().nullable()();

  /// Desktop navigation style: 'comfortable', 'compact', or 'icons'. Default 'comfortable'.
  TextColumn get desktopNavbarStyle =>
      text().withDefault(const Constant('comfortable'))();

  /// When true on desktop, the navigation sidebar hides automatically. Default false.
  BoolColumn get desktopNavbarAutohide =>
      boolean().withDefault(const Constant(false))();

  /// When true, tapping a track in an album queues the full album and starts
  /// at the selected track instead of queuing only that track. Default false.
  BoolColumn get albumQueueEnabled =>
      boolean().withDefault(const Constant(false))();

  /// When true, user queue actions expand configured Match Flows.
  BoolColumn get matchFlowEnabled =>
      boolean().withDefault(const Constant(false))();

  /// When true (and albumQueueEnabled is also true), tapping a track on the
  /// Liked page queues all liked songs and starts at the selected track.
  /// Default false.
  BoolColumn get likedQueueEnabled =>
      boolean().withDefault(const Constant(false))();

  /// User-provided Last.fm API key. Null when not configured or when a
  /// build-time key (NAVIS_LASTFM_API_KEY) is bundled instead.
  TextColumn get lastFmApiKey => text().nullable()();

  /// Whether Last.fm scrobbling is enabled. Secrets/session stay in secure
  /// storage; this only controls non-sensitive dispatch state.
  BoolColumn get lastFmScrobblingEnabled =>
      boolean().withDefault(const Constant(false))();

  /// True after Last.fm session auth succeeds. Cleared on invalid-session
  /// responses so the UI can ask the user to reconnect.
  BoolColumn get lastFmSessionConnected =>
      boolean().withDefault(const Constant(false))();

  /// Whether ListenBrainz scrobbling is enabled. The token stays in secure
  /// storage.
  BoolColumn get listenBrainzScrobblingEnabled =>
      boolean().withDefault(const Constant(false))();

  /// True after ListenBrainz token validation succeeds. Cleared on 401/403.
  BoolColumn get listenBrainzTokenValid =>
      boolean().withDefault(const Constant(false))();

  /// JSON-encoded custom Voyage server entries:
  /// [{"label":"Home","url":"https://voyage.example.com"}]
  TextColumn get customVoyageServers => text().nullable()();

  /// The app version+build string (e.g. "1.2.3+100") that was current when
  /// the last forced full sync was triggered. Null means no version-triggered
  /// full sync has run yet. Used to auto-force a full resync on app updates.
  TextColumn get lastFullSyncAppBuild => text().nullable()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
