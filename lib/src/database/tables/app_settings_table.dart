import 'package:drift/drift.dart';

class AppSettingsTable extends Table {
  @override
  String get tableName => 'app_settings';

  IntColumn get id => integer()();

  IntColumn get wifiMaxBitRate => integer().nullable()();

  TextColumn get wifiFormat => text().nullable()();

  IntColumn get cellularMaxBitRate => integer().nullable()();

  TextColumn get cellularFormat => text().nullable()();

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

  /// Theme mode: 'light', 'dark', 'oled', or 'system'. Defaults to 'dark'.
  TextColumn get themeMode => text().withDefault(const Constant('dark'))();

  /// Seed color for the app's ColorScheme. Null = dynamic / default blue.
  IntColumn get colorSchemeSeed => integer().nullable()();

  /// JSON-encoded list of custom color presets (ARGB32 ints).
  TextColumn get customColorPresets => text().nullable()();

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

  /// ReplayGain mode: 'off', 'track', or 'album'. Default 'off'.
  TextColumn get replayGainMode => text().withDefault(const Constant('off'))();

  /// ReplayGain pre-amp adjustment in dB (-6.0 to +6.0). Default 0.
  RealColumn get replayGainPreamp => real().withDefault(const Constant(0))();

  /// Playback speed multiplier (0.5–2.0). Default 1.0.
  RealColumn get playbackSpeed => real().withDefault(const Constant(1))();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
