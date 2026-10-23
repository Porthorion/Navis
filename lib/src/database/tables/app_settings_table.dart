import 'package:drift/drift.dart';

class AppSettingsTable extends Table {
  @override
  String get tableName => 'app_settings';

  IntColumn get id => integer()();

  /// Version of the latest first-run customization flow completed locally.
  /// Zero means the user has not completed a flow yet.
  IntColumn get onboardingVersion => integer().withDefault(const Constant(0))();

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

  BoolColumn get fastSeekingEnabled =>
      boolean().withDefault(const Constant(true))();

  BoolColumn get gaplessEnabled =>
      boolean().withDefault(const Constant(true))();

  BoolColumn get skipSilenceEnabled =>
      boolean().withDefault(const Constant(false))();

  BoolColumn get showAlbumsPage =>
      boolean().withDefault(const Constant(true))();

  BoolColumn get showRadioPage => boolean().withDefault(const Constant(true))();

  BoolColumn get showPlaylistsPage =>
      boolean().withDefault(const Constant(true))();

  BoolColumn get playlistCreateOnServer =>
      boolean().withDefault(const Constant(true))();

  BoolColumn get showArtistsPage =>
      boolean().withDefault(const Constant(true))();

  BoolColumn get showLikedPage => boolean().withDefault(const Constant(true))();

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

  /// `filesystem` for paths and `androidSaf` for persisted document-tree URIs.
  TextColumn get customDownloadFolderStorageKind =>
      text().withDefault(const Constant('filesystem'))();

  /// `ask` (show the quality picker), `original`, or `transcode`.
  TextColumn get downloadQualityMode =>
      text().withDefault(const Constant('ask'))();

  /// Bitrate (kbps) of transcoded downloads when the mode is `transcode`.
  IntColumn get downloadMaxBitRate =>
      integer().withDefault(const Constant(320))();

  /// Transcode format offered by the quality picker and used by `transcode`.
  TextColumn get downloadFormat => text().withDefault(const Constant('mp3'))();

  /// True once the one-time "always download in this quality?" prompt has
  /// been answered. Defaults to false so existing installs see it once.
  BoolColumn get downloadQualityPrompted =>
      boolean().withDefault(const Constant(false))();

  /// Number of downloads transferred at once (1 to 4). Cellular uses 1.
  IntColumn get maxConcurrentDownloads =>
      integer().withDefault(const Constant(2))();

  /// When true, queued downloads wait until the user resumes them.
  BoolColumn get downloadsPaused =>
      boolean().withDefault(const Constant(false))();

  /// Theme mode: 'light', 'dark', 'oled', or 'system'. Defaults to 'dark'.
  TextColumn get themeMode => text().withDefault(const Constant('dark'))();

  /// Colour style: 'neutral', 'pastel', 'immersive' or 'night'.
  /// Orthogonal to [themeMode].
  TextColumn get colorStyle => text().withDefault(const Constant('neutral'))();

  /// Uses OLED for the dark theme when the theme mode follows the system.
  BoolColumn get oledForAuto => boolean().withDefault(const Constant(false))();

  /// Switches to Night colour style during the daily schedule.
  BoolColumn get nightScheduleEnabled =>
      boolean().withDefault(const Constant(false))();

  /// Daily Night start in minutes after local midnight.
  IntColumn get nightScheduleStartMinutes =>
      integer().withDefault(const Constant(1320))();

  /// Daily Night end in minutes after local midnight.
  IntColumn get nightScheduleEndMinutes =>
      integer().withDefault(const Constant(420))();

  /// Disables surface glows, gradients and shadows when rendered.
  BoolColumn get flatSurfaces => boolean().withDefault(const Constant(false))();

  IntColumn get colorVividness => integer().withDefault(const Constant(0))();
  IntColumn get surfaceDepthLight => integer().withDefault(const Constant(0))();
  IntColumn get surfaceDepthDark => integer().withDefault(const Constant(0))();

  /// Independent background tint steps for Light and Dark/OLED.
  IntColumn get surfaceTintLight => integer().withDefault(const Constant(0))();
  IntColumn get surfaceTintDark => integer().withDefault(const Constant(0))();

  /// Filled controls use the accent or white with accent glyphs.
  TextColumn get controlColor => text().withDefault(const Constant('accent'))();

  TextColumn get appearanceLooks => text().withDefault(const Constant('[]'))();
  TextColumn get selectedAppearanceLookId => text().nullable()();

  IntColumn get flatAreas => integer().withDefault(const Constant(7))();

  BoolColumn get albumArtShade =>
      boolean().withDefault(const Constant(false))();

  BoolColumn get albumArtColoredShade =>
      boolean().withDefault(const Constant(false))();

  /// Seed color for the app's ColorScheme. Null = dynamic / default white.
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

  /// Legacy compatibility flag; nowPlayingBackground is authoritative.
  BoolColumn get artTintedNowPlaying =>
      boolean().withDefault(const Constant(true))();

  /// Chrome corners: rounded, soft or square.
  TextColumn get cornerStyle => text().withDefault(const Constant('rounded'))();

  /// Now Playing background: tinted, artwork or plain.
  TextColumn get nowPlayingBackground =>
      text().withDefault(const Constant('tinted'))();

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

  /// When true, automatic/background library sync waits for an unmetered
  /// network. Metered connections may still run a one-request probe and
  /// interactive hydration. Default true.
  BoolColumn get backgroundSyncUnmeteredOnly =>
      boolean().withDefault(const Constant(true))();

  /// Whether LRCLIB fallback is used when server lyrics are unavailable.
  BoolColumn get useLrclib => boolean().withDefault(const Constant(true))();

  /// When true, use legacy local-only Instant Mix instead of Last.fm Same Vibes.
  BoolColumn get legacyInstantMixEnabled =>
      boolean().withDefault(const Constant(false))();

  /// ReplayGain mode: 'off', 'track', or 'album'. Default 'off'.
  TextColumn get replayGainMode => text().withDefault(const Constant('off'))();

  /// ReplayGain pre-amp adjustment in dB (-6.0 to +6.0). Default 0.
  RealColumn get replayGainPreamp => real().withDefault(const Constant(0))();

  /// Playback speed multiplier. Default 1.0.
  RealColumn get playbackSpeed => real().withDefault(const Constant(1))();

  RealColumn get playbackPitchSemitones =>
      real().withDefault(const Constant(0))();

  BoolColumn get lockPitchToSpeed =>
      boolean().withDefault(const Constant(false))();

  /// JSON list of user presets; the immutable None preset is derived.
  TextColumn get playbackPresets => text().withDefault(const Constant('[]'))();

  /// Null denotes Custom.
  TextColumn get selectedPlaybackPresetId => text().nullable()();

  /// Album grid column count override. Null = auto (computed from width).
  /// Valid explicit values: 1–4.
  IntColumn get albumGridDensity => integer().nullable()();

  TextColumn get gridArtworkSize =>
      text().withDefault(const Constant('auto'))();

  BoolColumn get homeRecommendationsAutoAdvance =>
      boolean().withDefault(const Constant(false))();

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

  /// Legacy desktop compact-mode flag retained for schema compatibility only.
  BoolColumn get desktopFocusPlayerModeEnabled =>
      boolean().withDefault(const Constant(false))();

  /// Navis playback volume restored on desktop runtimes.
  RealColumn get desktopPlaybackVolume =>
      real().withDefault(const Constant(1))();

  /// Last non-muted desktop volume used by the mute toggle.
  RealColumn get desktopLastAudibleVolume =>
      real().withDefault(const Constant(1))();

  /// Home section density: 'comfortable' or 'compact'. Default 'comfortable'.
  TextColumn get homeDensity =>
      text().withDefault(const Constant('comfortable'))();

  /// JSON-encoded ordered list of home section IDs (e.g. ["recently_added",…]).
  /// Null = default order.
  TextColumn get homeSectionOrder => text().nullable()();

  /// JSON-encoded hidden Home section IDs.
  ///
  /// `null` uses the built-in default hidden set; `[]` hides nothing.
  TextColumn get homeSectionsHidden => text().nullable()();

  /// JSON-encoded ordered list of library page IDs. Null = default order.
  TextColumn get libraryPageOrder => text().nullable()();

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

  /// Deprecated compatibility column. Last.fm scrobble dispatch was removed.
  BoolColumn get lastFmScrobblingEnabled =>
      boolean().withDefault(const Constant(false))();

  /// Deprecated compatibility column. Last.fm session auth was removed.
  BoolColumn get lastFmSessionConnected =>
      boolean().withDefault(const Constant(false))();

  /// Whether ListenBrainz scrobbling is enabled. The token stays in secure
  /// storage.
  BoolColumn get listenBrainzScrobblingEnabled =>
      boolean().withDefault(const Constant(false))();

  /// True after ListenBrainz token validation succeeds. Cleared on 401/403.
  BoolColumn get listenBrainzTokenValid =>
      boolean().withDefault(const Constant(false))();

  /// MusicBrainz username returned by ListenBrainz token validation.
  TextColumn get listenBrainzUserName => text().nullable()();

  /// JSON-encoded custom Voyage server entries:
  /// [{"label":"Home","url":"https://voyage.example.com"}]
  TextColumn get customVoyageServers => text().nullable()();

  /// The "Online services" master switch. Off means Navis only talks to the
  /// user's server. Written only by the integration-policy writers, never by
  /// the full-row save.
  BoolColumn get externalIntegrationsEnabled =>
      boolean().withDefault(const Constant(true))();

  /// JSON list of switched-off integration service keys and feature keys that
  /// have no column of their own. Features stored in `useLrclib`,
  /// `updateCheckEnabled`, `listenBrainzScrobblingEnabled` and
  /// `legacyInstantMixEnabled` are never listed here. Written only by the
  /// integration-policy writers.
  TextColumn get disabledIntegrations =>
      text().withDefault(const Constant('[]'))();

  /// True once the one-time Integrations notice on Home was dismissed.
  BoolColumn get integrationsNoticeDismissed =>
      boolean().withDefault(const Constant(false))();

  /// JSON array of setup highlight storage keys already shown to the user.
  TextColumn get setupHighlightsSeen => text().nullable()();

  /// Latest setup highlight release acknowledged by completing setup.
  TextColumn get setupHighlightsSeenRelease => text().nullable()();

  /// Latest setup highlight release whose Home invitation was dismissed.
  TextColumn get setupCardDismissedRelease => text().nullable()();

  /// The app version+build string (e.g. "1.2.3+100") that was current when
  /// the last forced full sync was triggered. Null means no version-triggered
  /// full sync has run yet. Used to auto-force a full resync on app updates.
  TextColumn get lastFullSyncAppBuild => text().nullable()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
