// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'Navis';

  @override
  String get navHome => 'Home';

  @override
  String get navLibrary => 'Library';

  @override
  String get navSearch => 'Search';

  @override
  String get navRadio => 'Radio';

  @override
  String get navPlaylists => 'Playlists';

  @override
  String get navSettings => 'Settings';

  @override
  String get loginTitle => 'Sign in';

  @override
  String get loginSubtitle => 'Connect to your Subsonic or Navidrome server.';

  @override
  String get loginServerUrlLabel => 'Server URL';

  @override
  String get loginUsernameLabel => 'Username';

  @override
  String get loginPasswordLabel => 'Password';

  @override
  String get loginTestConnection => 'Test connection';

  @override
  String get loginTestingConnection => 'Testing connection...';

  @override
  String get loginConnect => 'Connect';

  @override
  String get loginConnecting => 'Connecting...';

  @override
  String get loginConnectSuccess => 'Connected successfully.';

  @override
  String get loginValidationServerUrlRequired => 'Server URL is required.';

  @override
  String get loginValidationServerUrlInvalid => 'Enter a valid server URL.';

  @override
  String get loginValidationServerUrlHttpsOnly => 'Use HTTPS for server URL.';

  @override
  String get loginInsecureHttpWarning =>
      'HTTP does not encrypt traffic. Use HTTPS when possible.';

  @override
  String get loginValidationUsernameRequired => 'Username is required.';

  @override
  String get loginValidationPasswordRequired => 'Password is required.';

  @override
  String get loginErrorAuthentication =>
      'Authentication failed. Check your credentials.';

  @override
  String get loginErrorConnection =>
      'Could not reach server. Check URL and network.';

  @override
  String get loginErrorUnknown => 'Unexpected error while connecting.';

  @override
  String loginTestConnectionSuccess(Object apiVersion) {
    return 'Connection successful (API $apiVersion).';
  }

  @override
  String get serverOfflineBanner => 'Server unreachable. Retrying every 30s.';

  @override
  String get serverOfflineQuietBanner => 'Offline mode';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsServerTitle => 'Configuration';

  @override
  String get settingsServerSubtitle =>
      'Server connection, account, and external services.';

  @override
  String get settingsCacheTitle => 'Cache';

  @override
  String get settingsCacheSubtitle =>
      'Manage storage for audio, cover art and downloads.';

  @override
  String get settingsDownloadsSubtitle => 'Manage offline downloads and queue.';

  @override
  String get settingsSyncTitle => 'Sync';

  @override
  String get settingsSyncSubtitle =>
      'Sync progress, history, and manual controls.';

  @override
  String get settingsPlaybackTitle => 'Playback';

  @override
  String get settingsPlaybackSubtitle =>
      'Stream quality, gapless, crossfade and equalizer.';

  @override
  String get settingsAppearanceTitle => 'Appearance';

  @override
  String get settingsAppearanceSubtitle =>
      'Themes, colors and display preferences.';

  @override
  String get syncSettingsTitle => 'Sync Settings';

  @override
  String get syncSettingsStatusLabel => 'Current sync status';

  @override
  String get syncSettingsLastSyncedLabel => 'Server last synced';

  @override
  String get syncSettingsNeverSynced => 'Never synced';

  @override
  String get syncSettingsStatusIdle => 'Idle';

  @override
  String get syncSettingsStatusSucceeded => 'Last sync succeeded';

  @override
  String get syncSettingsStatusFailed => 'Last sync failed';

  @override
  String get syncSettingsIntervalLabel => 'Auto-sync interval';

  @override
  String get syncSettingsIntervalManual => 'Manual only';

  @override
  String syncSettingsIntervalMinutes(Object minutes) {
    return 'Every $minutes minutes';
  }

  @override
  String syncSettingsIntervalHours(Object hours) {
    return 'Every $hours hour(s)';
  }

  @override
  String get syncSettingsIntervalDescription =>
      'How often the library syncs automatically in the background.';

  @override
  String playbackSettingsLoadError(Object message) {
    return 'Could not load playback settings: $message';
  }

  @override
  String get playbackSettingsWifiSectionTitle => 'Wi-Fi streaming';

  @override
  String get playbackSettingsWifiQualityLabel => 'Max bitrate';

  @override
  String get playbackSettingsWifiFormatLabel => 'Preferred format';

  @override
  String get playbackSettingsCellularSectionTitle => 'Cellular streaming';

  @override
  String get playbackSettingsCellularQualityLabel => 'Max bitrate';

  @override
  String get playbackSettingsCellularFormatLabel => 'Preferred format';

  @override
  String get playbackSettingsCachedFirstTitle => 'Cached First';

  @override
  String get playbackSettingsCachedFirstSubtitle =>
      'Prefer any complete cached file before requesting the active streaming profile.';

  @override
  String get playbackSettingsScrobbleTitle => 'Enable scrobbling';

  @override
  String get playbackSettingsScrobbleSubtitle =>
      'Report tracks you play to the server (now-playing and play counts). Disable to listen anonymously.';

  @override
  String get playbackSettingsLrclibTitle => 'Use LRCLIB fallback';

  @override
  String get playbackSettingsLrclibSubtitle =>
      'When server lyrics are unavailable, try LRCLIB and cache per song.';

  @override
  String get playbackSettingsGaplessTitle => 'Enable gapless playback';

  @override
  String get playbackSettingsGaplessSubtitle =>
      'Preload tracks to reduce gaps between songs.';

  @override
  String get playbackSettingsLegacyInstantMixTitle => 'Legacy Instant Mix';

  @override
  String get playbackSettingsLegacyInstantMixSubtitle =>
      'Use local-only similar songs instead of Last.fm recommendations.';

  @override
  String get playbackSettingsLegacyInstantMixLocked =>
      'This build has no Last.fm API key, so Legacy Instant Mix is required.';

  @override
  String get playbackSettingsShowRadioPageTitle => 'Show Radio page';

  @override
  String get playbackSettingsShowRadioPageSubtitle =>
      'Display the Radio tab in bottom navigation.';

  @override
  String get playbackSettingsAndroidDspSectionTitle => 'Android Audio Effects';

  @override
  String get playbackSettingsEqualizerTitle => 'Enable equalizer';

  @override
  String get playbackSettingsEqualizerSubtitle =>
      'Adjust frequency bands for Android playback.';

  @override
  String playbackSettingsEqualizerBandLabel(int index) {
    return 'Band $index';
  }

  @override
  String get playbackSettingsLoudnessTitle => 'Enable loudness enhancer';

  @override
  String get playbackSettingsLoudnessSubtitle =>
      'Apply target gain in dB on Android playback.';

  @override
  String get playbackSettingsSaveAction => 'Save';

  @override
  String get playbackSettingsResetAction => 'Reset defaults';

  @override
  String get playbackSettingsQualityOriginal => 'Original quality';

  @override
  String playbackSettingsQualityKbps(int kbps) {
    return '$kbps kbps';
  }

  @override
  String get playbackSettingsFormatOriginal => 'Server default';

  @override
  String get playbackSettingsSaveSuccess => 'Playback settings saved.';

  @override
  String playbackSettingsSaveFailure(Object message) {
    return 'Could not save playback settings: $message';
  }

  @override
  String get playbackSettingsResetSuccess =>
      'Playback settings reset to defaults.';

  @override
  String playbackSettingsResetFailure(Object message) {
    return 'Could not reset playback settings: $message';
  }

  @override
  String get playbackSettingsCrossfadeSectionTitle => 'Cross-fade';

  @override
  String get playbackSettingsCrossfadeEnableTitle => 'Enable cross-fade';

  @override
  String get playbackSettingsCrossfadeEnableSubtitle =>
      'Smoothly blend the end of one track into the start of the next.';

  @override
  String playbackSettingsCrossfadeDurationLabel(int seconds) {
    return 'Duration: ${seconds}s';
  }

  @override
  String get playbackSettingsCrossfadeTypeLabel => 'Cross-fade mode';

  @override
  String get playbackSettingsCrossfadeTypeNormal => 'Normal';

  @override
  String get playbackSettingsCrossfadeTypeNormalDescription =>
      'Cross-fade between every track.';

  @override
  String get playbackSettingsCrossfadeTypeSmart => 'Smart';

  @override
  String get playbackSettingsCrossfadeTypeSmartDescription =>
      'Only cross-fade between tracks from different albums.';

  @override
  String get playbackSettingsCrossfadeGaplessWarning =>
      'Crossfade and gapless playback are both enabled. These features conflict — crossfade may not work correctly. Consider disabling one.';

  @override
  String get playbackSettingsReplayGainSectionTitle =>
      'Volume Normalization (ReplayGain)';

  @override
  String get playbackSettingsReplayGainModeLabel => 'ReplayGain mode';

  @override
  String get playbackSettingsReplayGainModeOff => 'Off';

  @override
  String get playbackSettingsReplayGainModeOffDescription =>
      'No volume normalization applied.';

  @override
  String get playbackSettingsReplayGainModeTrack => 'Track';

  @override
  String get playbackSettingsReplayGainModeTrackDescription =>
      'Normalize volume on a per-track basis.';

  @override
  String get playbackSettingsReplayGainModeAlbum => 'Album';

  @override
  String get playbackSettingsReplayGainModeAlbumDescription =>
      'Normalize volume on a per-album basis, preserving relative loudness.';

  @override
  String get playbackSettingsReplayGainPreampLabel => 'Pre-amp (dB)';

  @override
  String get playbackSettingsReplayGainPreampSubtitle =>
      'Additional gain adjustment. Range: −6 to +6 dB.';

  @override
  String get playbackSettingsPlaybackSpeedLabel => 'Playback speed';

  @override
  String get playbackSettingsPlaybackSpeedSubtitle =>
      'Adjust playback tempo (0.5× – 2.0×). Default: 1.0×.';

  @override
  String get playbackSettingsAlbumQueueTitle => 'Album Queue';

  @override
  String get playbackSettingsAlbumQueueSubtitle =>
      'Tapping a track in an album queues the entire album and starts playback at that track.';

  @override
  String get playbackSettingsLikedQueueTitle => 'Liked Queue';

  @override
  String get playbackSettingsLikedQueueSubtitle =>
      'Tapping a track on the Liked page queues all your liked songs and starts at that track.';

  @override
  String get homeTitle => 'Home';

  @override
  String get homeLoadErrorTitle => 'Could not load section';

  @override
  String get homeContinueListeningTitle => 'Continue listening';

  @override
  String get homeContinueListeningResume => 'Resume';

  @override
  String get homeContinueListeningOpenNowPlaying => 'Open player';

  @override
  String get homeRecentlyLikedAlbumsTitle => 'Recently liked albums';

  @override
  String get homeRecentlyLikedAlbumsEmptyTitle => 'No liked albums yet';

  @override
  String get homeRecentlyLikedAlbumsEmptySubtitle =>
      'Like albums to pin your favorites here.';

  @override
  String get homeRecentlyPlayedTitle => 'Recently played';

  @override
  String get homeRecentlyPlayedEmptyTitle => 'No recent plays yet';

  @override
  String get homeRecentlyPlayedEmptySubtitle =>
      'Start playback to populate this section.';

  @override
  String get homeRecentlyAddedTitle => 'Recently added';

  @override
  String get homeRecentlyAddedEmptyTitle => 'No recently added albums';

  @override
  String get homeRecentlyAddedEmptySubtitle =>
      'Pull to refresh to fetch newly added albums.';

  @override
  String get homeFrequentTitle => 'Frequent albums';

  @override
  String get homeFrequentEmptyTitle => 'No frequent albums yet';

  @override
  String get homeFrequentEmptySubtitle =>
      'Play more tracks to build listening history.';

  @override
  String get homeRandomTitle => 'You Might Like';

  @override
  String get homeRandomEmptyTitle => 'No recommendations available';

  @override
  String get homeRandomEmptySubtitle =>
      'Like more songs or pull to refresh to discover new picks.';

  @override
  String get homeStarredTitle => 'Liked tracks';

  @override
  String get homeStarredEmptyTitle => 'No liked tracks';

  @override
  String get homeStarredEmptySubtitle =>
      'Like tracks on your server to see them here.';

  @override
  String get homeSeeAll => 'See all';

  @override
  String get homeMostPlayedTracksTitle => 'Most played tracks';

  @override
  String get homeMostPlayedTracksEmptyTitle => 'No play data yet';

  @override
  String get homeMostPlayedTracksEmptySubtitle =>
      'Play more music to populate this section.';

  @override
  String get homeRecentlyPlayedTracksTitle => 'Recently played tracks';

  @override
  String get homeRecentlyPlayedTracksEmptyTitle => 'No recently played tracks';

  @override
  String get homeRecentlyPlayedTracksEmptySubtitle =>
      'Start listening to populate this section.';

  @override
  String get homeRecentlyPlayedAlbumsTitle => 'Recently played albums';

  @override
  String get homeRecentlyPlayedAlbumsEmptyTitle => 'No recently played albums';

  @override
  String get homeRecentlyPlayedAlbumsEmptySubtitle =>
      'Start listening to populate this section.';

  @override
  String get homeQuickActionsTitle => 'Quick actions';

  @override
  String get homeQuickActionShuffleLiked => 'Shuffle liked';

  @override
  String get radioTitle => 'Radio';

  @override
  String get radioEmptyTitle => 'No radio stations found';

  @override
  String get radioEmptySubtitle =>
      'Add internet radio stations on your server to see them here.';

  @override
  String get radioLoadErrorTitle => 'Could not load radio stations';

  @override
  String get radioUnsupportedMessage =>
      'This server does not expose internet radio station endpoints.';

  @override
  String get radioStopStation => 'Stop radio';

  @override
  String get radioPlaybackError => 'Could not play this radio station.';

  @override
  String get radioStreamUnavailable => 'Radio stream unavailable.';

  @override
  String get radioNowPlaying => 'Now playing on radio';

  @override
  String get radioLive => 'LIVE';

  @override
  String get serverSettingsTitle => 'Configuration';

  @override
  String get serverSettingsLoadError => 'Could not load server settings.';

  @override
  String get serverSettingsSaveError => 'Failed to save. Please try again.';

  @override
  String get serverSettingsNotAuthenticated =>
      'No active server session. Sign in to manage server settings.';

  @override
  String get serverSettingsCurrentConnection => 'Current connection';

  @override
  String get serverSettingsNameLabel => 'Name';

  @override
  String get serverSettingsUrlLabel => 'URL';

  @override
  String get serverSettingsUsernameLabel => 'Username';

  @override
  String get serverSettingsApiVersionLabel => 'API version';

  @override
  String get serverSettingsAuthModeLabel => 'Auth mode';

  @override
  String get serverSettingsAuthModeToken => 'Token';

  @override
  String get serverSettingsAuthModeLegacy => 'Legacy password';

  @override
  String get serverSettingsCapabilitiesLabel => 'Capabilities';

  @override
  String get serverSettingsCapabilitiesEmpty => 'None detected';

  @override
  String serverSettingsCapabilitiesCount(int count) {
    return '$count extension(s)';
  }

  @override
  String get serverSettingsUnknownValue => 'Unknown';

  @override
  String get serverSettingsTestConnection => 'Test connection';

  @override
  String get serverSettingsSave => 'Save';

  @override
  String get serverSettingsSaving => 'Saving...';

  @override
  String get serverSettingsSaveSuccess => 'Server settings saved.';

  @override
  String get serverSettingsForceFullSync => 'Force Full Sync';

  @override
  String get serverSettingsForceFullSyncRunning => 'Sync in progress...';

  @override
  String get serverSettingsForceFullSyncSuccess =>
      'Full library sync completed.';

  @override
  String serverSettingsForceFullSyncFailure(Object message) {
    return 'Full sync failed: $message';
  }

  @override
  String get serverSettingsSignOut => 'Sign out';

  @override
  String get serverSettingsSignOutKeepData => 'Sign out (keep local data)';

  @override
  String get serverSettingsSignOutKeepDataSubtitle =>
      'Remove credentials but keep downloaded and cached metadata.';

  @override
  String get serverSettingsSignOutWipeData => 'Sign out and clear local data';

  @override
  String get serverSettingsSignOutWipeDataSubtitle =>
      'Remove credentials and wipe local library, cache, and history metadata.';

  @override
  String get serverSettingsSignOutSuccess =>
      'Signed out. Local data was preserved.';

  @override
  String get serverSettingsSignOutWipeSuccess =>
      'Signed out and local data cleared.';

  @override
  String get serverSettingsSignOutError =>
      'Could not complete sign out. Try again.';

  @override
  String get configurationServerSection => 'Server';

  @override
  String get configurationExternalServicesSection => 'External services';

  @override
  String get configurationLastFmSection => 'Last.fm';

  @override
  String get configurationLastFmApiKeyLabel => 'API Key';

  @override
  String get configurationLastFmApiKeyHint => 'Paste your Last.fm API key here';

  @override
  String get configurationLastFmGetApiKey => 'Get API Key';

  @override
  String get configurationLastFmApiKeySaved => 'Last.fm API key saved.';

  @override
  String get configurationLastFmApiKeyCleared => 'Last.fm API key removed.';

  @override
  String get configurationLastFmBundledNotice =>
      'API key bundled with this build';

  @override
  String get configurationLastFmBundledSubtitle =>
      'This build includes a Last.fm API key. You do not need to provide your own.';

  @override
  String get commonQueued => 'Queued';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get libraryTitle => 'Library';

  @override
  String get libraryTabArtists => 'Artists';

  @override
  String get libraryTabAlbums => 'Albums';

  @override
  String get libraryTabLiked => 'Liked';

  @override
  String get libraryTabSongs => 'Songs';

  @override
  String get libraryTabGenres => 'Genres';

  @override
  String get librarySyncRunning => 'Syncing library metadata...';

  @override
  String librarySyncRunningStage(Object stage) {
    return 'Syncing: $stage';
  }

  @override
  String librarySyncRunningWithProgress(int processed, int total) {
    return 'Syncing library metadata ($processed/$total)';
  }

  @override
  String librarySyncLastSynced(Object timestamp) {
    return 'Last synced: $timestamp';
  }

  @override
  String get librarySyncStagePreparing => 'Preparing';

  @override
  String get librarySyncStageArtists => 'Fetching artists';

  @override
  String get librarySyncStageAlbums => 'Fetching albums';

  @override
  String get librarySyncStagePersisting => 'Persisting metadata';

  @override
  String get librarySyncStageSongs => 'Hydrating songs';

  @override
  String get librarySyncStageGenres => 'Fetching genres';

  @override
  String get librarySyncStagePlaylists => 'Fetching playlists';

  @override
  String get librarySyncStageFinalizing => 'Finalizing';

  @override
  String get librarySyncFailureFallback => 'Library sync failed.';

  @override
  String get librarySyncHydratingUnknown =>
      'Metadata ready. Hydrating songs...';

  @override
  String librarySyncHydratingProgress(int processed, int total, int pending) {
    return 'Metadata ready. Hydrating songs ($processed/$total, $pending remaining)';
  }

  @override
  String librarySyncHydratingProgressWithRate(
    int processed,
    int total,
    int pending,
    Object rate,
  ) {
    return 'Metadata ready. Hydrating songs ($processed/$total, $pending remaining, $rate albums/s)';
  }

  @override
  String get libraryArtistsEmptyTitle => 'No artists found';

  @override
  String get libraryArtistsEmptySubtitle =>
      'Run a sync to populate your library.';

  @override
  String get libraryArtistsIndexAll => 'All';

  @override
  String get libraryArtistsErrorTitle => 'Could not load artists';

  @override
  String get libraryLikedAlbumsSectionTitle => 'Liked Albums';

  @override
  String get libraryLikedAlbumsSeeAll => 'See all';

  @override
  String get libraryLikedAlbumsAllTitle => 'Liked Albums';

  @override
  String get libraryLikedSongsSectionTitle => 'Liked Songs';

  @override
  String get libraryLikedEmptyTitle => 'Nothing liked yet';

  @override
  String get libraryLikedEmptySubtitle =>
      'Like albums or songs to see them here.';

  @override
  String get libraryLikedOnlyFilter => 'Liked';

  @override
  String get libraryLikedOnlyEmptyTitle => 'No liked matches';

  @override
  String get libraryLikedOnlyEmptySubtitle =>
      'Try turning off the liked filter or like more content.';

  @override
  String get libraryAlbumsEmptyTitle => 'No albums found';

  @override
  String get libraryAlbumsEmptySubtitle =>
      'Run a sync to populate your library.';

  @override
  String get libraryAlbumsErrorTitle => 'Could not load albums';

  @override
  String get libraryAlbumsByYearEmptyTitle => 'No albums with year data';

  @override
  String get libraryAlbumsByYearEmptySubtitle =>
      'Sync more metadata or change filters to browse by year.';

  @override
  String get libraryAlbumsSortLabel => 'Sort albums by';

  @override
  String libraryAlbumsPagingProgress(int loaded, int total) {
    return 'Loaded $loaded of $total albums';
  }

  @override
  String get librarySongsEmptyTitle => 'No songs found';

  @override
  String get librarySongsEmptySubtitle =>
      'Run a sync to populate your library.';

  @override
  String get librarySongsErrorTitle => 'Could not load songs';

  @override
  String get librarySongsSortLabel => 'Sort songs by';

  @override
  String get libraryGenresEmptyTitle => 'No genres found';

  @override
  String get libraryGenresEmptySubtitle =>
      'Run a sync to populate your library.';

  @override
  String get libraryGenresErrorTitle => 'Could not load genres';

  @override
  String libraryGenresCount(int albums, int songs) {
    return '$albums albums • $songs songs';
  }

  @override
  String get librarySortRecentlyAdded => 'Recently Added';

  @override
  String get librarySortNewest => 'Newest (Year)';

  @override
  String get librarySortByYear => 'By Year';

  @override
  String get librarySortOldest => 'Oldest';

  @override
  String get librarySortName => 'Name';

  @override
  String get librarySortArtist => 'Artist';

  @override
  String get librarySortArtistAlbum => 'Artist / Album';

  @override
  String get librarySortTitle => 'Title';

  @override
  String get librarySortDuration => 'Duration';

  @override
  String get libraryArtistMenuOpen => 'Open artist';

  @override
  String get libraryAlbumMenuOpen => 'Open album';

  @override
  String get librarySongMenuPlayNow => 'Play now';

  @override
  String get librarySongMenuAddToQueue => 'Add to queue';

  @override
  String get librarySongMenuPlayNext => 'Play next';

  @override
  String get librarySongMenuOpenAlbum => 'Open album';

  @override
  String get librarySongMenuOpenArtist => 'Open artist';

  @override
  String librarySongPlayNowQueued(Object title) {
    return '\"$title\" queued to play now.';
  }

  @override
  String librarySongAddedToQueue(Object title) {
    return '\"$title\" added to queue.';
  }

  @override
  String librarySongPlayNextQueued(Object title) {
    return '\"$title\" added to play next.';
  }

  @override
  String libraryGenreDetailTitle(Object genre) {
    return '$genre';
  }

  @override
  String get libraryGenreAlbumsTab => 'Albums';

  @override
  String get libraryGenreSongsTab => 'Songs';

  @override
  String get libraryGenreAlbumsEmptyTitle => 'No albums in this genre';

  @override
  String get libraryGenreAlbumsEmptySubtitle => 'Sync to refresh genre albums.';

  @override
  String get libraryGenreSongsEmptyTitle => 'No songs in this genre';

  @override
  String get libraryGenreSongsEmptySubtitle => 'Sync to refresh genre songs.';

  @override
  String get libraryGenreLoadErrorTitle => 'Could not load genre';

  @override
  String artistCardAlbumCount(int count) {
    return '$count albums';
  }

  @override
  String get artistDetailTitle => 'Artist';

  @override
  String get artistDetailNotFoundTitle => 'Artist not found';

  @override
  String get artistDetailNotFoundSubtitle =>
      'This artist is not available in local data.';

  @override
  String artistDetailAlbumCount(int count) {
    return '$count albums';
  }

  @override
  String get artistDetailAlbumsEmptyTitle => 'No albums for this artist';

  @override
  String get artistDetailAlbumsEmptySubtitle =>
      'Sync your library to load artist albums.';

  @override
  String get artistDetailAlbumsSection => 'Albums';

  @override
  String get artistDetailFeaturedSection => 'Featured In';

  @override
  String get artistDetailUnknownYear => 'Unknown year';

  @override
  String get artistDetailBioSection => 'Biography';

  @override
  String get artistDetailSimilarSection => 'Similar artists';

  @override
  String get artistDetailAlbumsErrorTitle => 'Could not load artist albums';

  @override
  String get artistDetailLoadErrorTitle => 'Could not load artist details';

  @override
  String get artistTopTracksSection => 'Top Tracks';

  @override
  String get artistTopTracksShowMore => 'Show more';

  @override
  String get artistTopTracksShowLess => 'Show less';

  @override
  String artistTopTracksListeners(String count) {
    return '$count listeners';
  }

  @override
  String get artistTopTracksNotAvailable =>
      'Track not available in your library.';

  @override
  String get artistTopTracksPlayError => 'Could not play track. Try again.';

  @override
  String artistTopTracksPlaylistTitle(String artist) {
    return 'This is $artist';
  }

  @override
  String get artistTopTracksPlaylistUnavailable =>
      'Not available in your library';

  @override
  String get artistTopTracksPlaylistSearchAction => 'Search';

  @override
  String get artistTopTracksPlaylistEmptyTitle => 'No top tracks';

  @override
  String get artistTopTracksPlaylistEmptySubtitle =>
      'Last.fm did not return tracks for this artist.';

  @override
  String get artistTopTracksPlaylistErrorTitle => 'Failed to load top tracks';

  @override
  String get albumDetailTitle => 'Album';

  @override
  String get albumDetailNotFoundTitle => 'Album not found';

  @override
  String get albumDetailNotFoundSubtitle =>
      'This album is not available in local data.';

  @override
  String get albumDetailUnknownArtist => 'Unknown artist';

  @override
  String albumDetailMeta(Object artist, Object year, int trackCount) {
    return '$artist • $year • $trackCount tracks';
  }

  @override
  String get albumDetailTracksEmptyTitle => 'No tracks for this album';

  @override
  String get albumDetailTracksEmptySubtitle =>
      'Sync your library to load album tracks.';

  @override
  String get albumDetailLikedTracksEmptyTitle =>
      'No liked tracks in this album';

  @override
  String get albumDetailLikedTracksEmptySubtitle =>
      'None of the tracks in this album have been liked yet.';

  @override
  String get albumDetailShowAllTracksAction => 'Show all tracks';

  @override
  String get albumDetailFilterLabel => 'Filters';

  @override
  String get albumDetailLoadErrorTitle => 'Could not load album details';

  @override
  String get albumDetailPlayAction => 'Play';

  @override
  String get albumDetailShuffleAction => 'Shuffle';

  @override
  String get albumDetailStarAction => 'Like';

  @override
  String get albumDetailDownloadAction => 'Download Album';

  @override
  String get albumDetailDownloadActionQueued => 'Album queued for download.';

  @override
  String get albumDetailPlayActionQueued => 'Album queued for playback.';

  @override
  String get albumDetailShuffleActionQueued => 'Album shuffled into queue.';

  @override
  String get albumDetailStarFailure => 'Could not update like status.';

  @override
  String get albumDetailAboutSection => 'About this album';

  @override
  String get albumDetailMenuShowAlbumArt => 'Show album art';

  @override
  String get albumDetailLastFm => 'Last.fm';

  @override
  String get albumDetailMusicBrainz => 'MusicBrainz';

  @override
  String albumDetailDiscHeader(int number) {
    return 'Disc $number';
  }

  @override
  String get cacheBadgeLabel => 'Cached';

  @override
  String get miniPlayerUnknownTrack => 'Unknown track';

  @override
  String get miniPlayerUnknownArtist => 'Unknown artist';

  @override
  String get miniPlayerPlay => 'Play';

  @override
  String get miniPlayerPause => 'Pause';

  @override
  String get miniPlayerSkipNext => 'Skip to next';

  @override
  String get playbackBootstrapLoadingTitle => 'Preparing playback';

  @override
  String get playbackBootstrapLoadingSubtitle =>
      'Restoring your listening session…';

  @override
  String get playbackBootstrapFailedTitle => 'Playback initialization failed';

  @override
  String get playbackBootstrapFailedSubtitle =>
      'Could not initialize playback. Retry to continue.';

  @override
  String get playbackBootstrapRetryAction => 'Retry playback startup';

  @override
  String get playbackUnavailableInitializing =>
      'Playback is still initializing. Try again in a moment.';

  @override
  String get playbackUnavailableStartupFailed =>
      'Playback startup failed. Retry from the startup screen.';

  @override
  String get playbackUnavailableSource =>
      'Could not resolve an audio source. Check server session and connection.';

  @override
  String get playbackUnavailableGeneric => 'Playback is unavailable right now.';

  @override
  String get playbackActionFailed =>
      'Playback action failed. Please try again.';

  @override
  String get commonLoading => 'Loading…';

  @override
  String get queueTitle => 'Queue';

  @override
  String get queueUnknownTrack => 'Unknown track';

  @override
  String get queueUnknownArtist => 'Unknown artist';

  @override
  String get queueTrackLoadError => 'Error loading track';

  @override
  String get queueClearAction => 'Clear queue';

  @override
  String get queueClearConfirmTitle => 'Clear queue?';

  @override
  String get queueClearConfirmMessage =>
      'This will remove all tracks from the queue.';

  @override
  String get queueEmptyTitle => 'Queue is empty';

  @override
  String get queueEmptySubtitle => 'Add tracks to start playing.';

  @override
  String get cancelAction => 'Cancel';

  @override
  String get nowPlayingTitle => 'Now Playing';

  @override
  String get nowPlayingUnknownTrack => 'Unknown track';

  @override
  String get nowPlayingUnknownArtist => 'Unknown artist';

  @override
  String get nowPlayingUnknownAlbum => 'Unknown album';

  @override
  String get nowPlayingShuffle => 'Shuffle';

  @override
  String get nowPlayingShuffleOff => 'Shuffle off';

  @override
  String get nowPlayingPrevious => 'Previous';

  @override
  String get nowPlayingPlay => 'Play';

  @override
  String get nowPlayingPause => 'Pause';

  @override
  String get nowPlayingNext => 'Next';

  @override
  String get nowPlayingRepeatOff => 'Repeat off';

  @override
  String get nowPlayingRepeatAll => 'Repeat all';

  @override
  String get nowPlayingRepeatOne => 'Repeat one';

  @override
  String get nowPlayingStar => 'Like';

  @override
  String get nowPlayingLyrics => 'Lyrics';

  @override
  String get nowPlayingQueue => 'Queue';

  @override
  String nowPlayingQueuePosition(int current, int total) {
    return 'Playing $current of $total';
  }

  @override
  String get nowPlayingInstantMix => 'Start Instant Mix';

  @override
  String get nowPlayingInstantMixLabel => 'Instant Mix';

  @override
  String get nowPlayingInstantMixStop => 'Stop Instant Mix';

  @override
  String get nowPlayingInstantMixActive => 'Instant Mix — tap to stop';

  @override
  String get nowPlayingInstantMixDescription => 'Classic similar-song queueing';

  @override
  String nowPlayingInstantMixStarted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Instant Mix started — $count similar tracks queued.',
      one: 'Instant Mix started — 1 similar track queued.',
      zero: 'No similar tracks found.',
    );
    return '$_temp0';
  }

  @override
  String get nowPlayingInstantMixUnsupported =>
      'Your server doesn\'t support Instant Mix.';

  @override
  String get nowPlayingInstantMixError => 'Couldn\'t start Instant Mix.';

  @override
  String get nowPlayingSameVibesLabel => 'Same Vibes';

  @override
  String get nowPlayingSameVibesDescription => 'Last.fm similar-song queueing';

  @override
  String nowPlayingSameVibesStarted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Same Vibes started — $count similar tracks queued.',
      one: 'Same Vibes started — 1 similar track queued.',
      zero: 'No similar tracks found.',
    );
    return '$_temp0';
  }

  @override
  String get nowPlayingSameVibesUnsupported =>
      'Your server doesn\'t support similar-track lookups.';

  @override
  String get nowPlayingSameVibesError => 'Couldn\'t start Same Vibes.';

  @override
  String get nowPlayingSameVibesStopped => 'Same Vibes stopped.';

  @override
  String get nowPlayingMixTitle => 'Queue modes';

  @override
  String get nowPlayingMixSubtitle =>
      'Choose how similar tracks should be added next.';

  @override
  String get nowPlayingMore => 'More options';

  @override
  String get nowPlayingGoToAlbum => 'Go to album';

  @override
  String get nowPlayingGoToArtist => 'Go to artist';

  @override
  String get nowPlayingAudioQuality => 'Audio quality';

  @override
  String get nowPlayingReleaseDate => 'Release date';

  @override
  String get lyricsTitle => 'Lyrics';

  @override
  String get lyricsNoneAvailable => 'No lyrics available';

  @override
  String get lyricsError => 'Could not load lyrics. Check your connection.';

  @override
  String get lyricsUnsupported => 'Lyrics not supported by this server.';

  @override
  String get lyricsSourceServerSynced => 'Lyrics source: Server (synced)';

  @override
  String get lyricsSourceServerPlain => 'Lyrics source: Server';

  @override
  String get lyricsSourceLrclibSynced => 'Lyrics source: LRCLIB (synced)';

  @override
  String get lyricsSourceLrclibPlain => 'Lyrics source: LRCLIB';

  @override
  String get lyricsAttributionLrclib => 'Lyrics provided by LRCLIB';

  @override
  String get ratingTitle => 'Rating';

  @override
  String get ratingHint => 'Tap a star to set or clear';

  @override
  String get ratingNoValue => 'No rating';

  @override
  String get ratingNotLiked => 'Not liked';

  @override
  String ratingValueShort(int rating) {
    return '$rating/5';
  }

  @override
  String get ratingUpdateFailed => 'Could not update rating.';

  @override
  String get queueSaveAsPlaylist => 'Save as playlist';

  @override
  String get queueSaveAsPlaylistName => 'Playlist name';

  @override
  String get queueSaveAsPlaylistSaved => 'Playlist saved';

  @override
  String get searchHint => 'Search artists, albums, songs...';

  @override
  String get searchRecentTitle => 'Recent searches';

  @override
  String get searchClearRecent => 'Clear';

  @override
  String get searchNoResults => 'No results found';

  @override
  String get searchNoResultsSubtitle => 'Try a different search term.';

  @override
  String get searchArtistsSection => 'Artists';

  @override
  String get searchAlbumsSection => 'Albums';

  @override
  String get searchSongsSection => 'Songs';

  @override
  String get searchShowAll => 'Show all';

  @override
  String get searchShowLess => 'Show less';

  @override
  String searchAlbumCount(int count) {
    return '$count albums';
  }

  @override
  String get searchPlayNext => 'Play next';

  @override
  String get searchAddToQueue => 'Add to queue';

  @override
  String get searchFilterAll => 'All';

  @override
  String get searchLocalOfflineBanner => 'Searching local library (offline)';

  @override
  String get playlistsTitle => 'Playlists';

  @override
  String get playlistsEmpty => 'No playlists yet';

  @override
  String get playlistsEmptySubtitle => 'Create a playlist to get started.';

  @override
  String get playlistsLoadError => 'Failed to load playlists';

  @override
  String playlistsSongCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count songs',
      one: '1 song',
      zero: 'No songs',
    );
    return '$_temp0';
  }

  @override
  String get playlistsCreateAction => 'New playlist';

  @override
  String get playlistsCreateTitle => 'Create playlist';

  @override
  String get playlistsCreateNameLabel => 'Playlist name';

  @override
  String get playlistsCreateSuccess => 'Playlist created';

  @override
  String get playlistsCreateFailed => 'Failed to create playlist';

  @override
  String get playlistsDeleteConfirmTitle => 'Delete playlist?';

  @override
  String playlistsDeleteConfirmMessage(String name) {
    return 'This will permanently delete \"$name\".';
  }

  @override
  String get playlistsDeleteSuccess => 'Playlist deleted';

  @override
  String get playlistsDeleteFailed => 'Failed to delete playlist';

  @override
  String get playlistsRenameTitle => 'Rename playlist';

  @override
  String get playlistsRenameLabel => 'New name';

  @override
  String get playlistsRenameSuccess => 'Playlist renamed';

  @override
  String get playlistsRenameFailed => 'Failed to rename playlist';

  @override
  String get playlistDetailTitle => 'Playlist';

  @override
  String get playlistDetailPlayAction => 'Play';

  @override
  String get playlistDetailShuffleAction => 'Shuffle';

  @override
  String playlistDetailMeta(String owner, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count songs',
      one: '1 song',
      zero: 'No songs',
    );
    return '$owner · $_temp0';
  }

  @override
  String get playlistDetailNotFound => 'Playlist not found';

  @override
  String get playlistDetailNotFoundSubtitle => 'It may have been deleted.';

  @override
  String get playlistDetailLoadError => 'Failed to load playlist';

  @override
  String get playlistDetailEmptyTitle => 'No tracks';

  @override
  String get playlistDetailEmptySubtitle => 'Add songs from the library.';

  @override
  String get playlistDetailRemoveTrack => 'Remove from playlist';

  @override
  String get playlistDetailTrackRemoved => 'Track removed';

  @override
  String get playlistDetailTrackRemoveFailed => 'Failed to remove track';

  @override
  String get addToPlaylistTitle => 'Add to playlist';

  @override
  String addToPlaylistSuccess(String name) {
    return 'Added to \"$name\"';
  }

  @override
  String get addToPlaylistFailed => 'Failed to add to playlist';

  @override
  String get addToPlaylistNewPlaylist => 'New playlist';

  @override
  String get librarySongMenuAddToPlaylist => 'Add to playlist';

  @override
  String get cacheSettingsTitle => 'Cache & Storage';

  @override
  String get cacheSettingsRollingSection => 'Streaming cache';

  @override
  String get cacheSettingsRollingDescription =>
      'Recently streamed tracks are cached automatically. Oldest tracks are evicted when the budget is exceeded.';

  @override
  String get cacheSettingsRollingBudgetLabel => 'Cache budget';

  @override
  String cacheSettingsRollingCurrentSize(String used, String budget) {
    return '$used / $budget';
  }

  @override
  String cacheSettingsRollingTrackCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count cached tracks',
      one: '1 cached track',
      zero: 'No cached tracks',
    );
    return '$_temp0';
  }

  @override
  String get cacheSettingsClearRolling => 'Clear streaming cache';

  @override
  String get cacheSettingsClearRollingConfirm =>
      'Clear all cached streaming audio? This cannot be undone.';

  @override
  String get cacheSettingsPermanentSection => 'Downloaded tracks';

  @override
  String cacheSettingsPermanentTrackCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count downloaded tracks',
      one: '1 downloaded track',
      zero: 'No downloaded tracks',
    );
    return '$_temp0';
  }

  @override
  String get cacheSettingsClearPermanent => 'Remove all downloads';

  @override
  String get cacheSettingsClearPermanentConfirm =>
      'Remove all downloaded tracks? This cannot be undone.';

  @override
  String get cacheSettingsClearCoverArt => 'Clear cover art cache';

  @override
  String get cacheSettingsClearCoverArtConfirm =>
      'Clear all cached cover art images?';

  @override
  String get cacheSettingsClearSuccess => 'Cache cleared.';

  @override
  String get cacheSettingsBudgetSaved => 'Cache budget updated.';

  @override
  String cacheSettingsBudgetGb(String gb) {
    return '$gb GB';
  }

  @override
  String get cacheSettingsUnlimited => 'Unlimited';

  @override
  String get downloadQualityTitle => 'Download quality';

  @override
  String get downloadQualityOriginal => 'Original quality';

  @override
  String get downloadQualityOriginalSub => 'Lossless / as stored on server';

  @override
  String get downloadQuality320 => '320 kbps MP3';

  @override
  String get downloadQuality192 => '192 kbps MP3';

  @override
  String get downloadQuality128 => '128 kbps MP3';

  @override
  String get downloadAction => 'Download';

  @override
  String get downloadSongQueued => 'Download queued.';

  @override
  String downloadAlbumQueued(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tracks queued for download',
      one: '1 track queued for download',
      zero: 'All tracks already downloaded',
    );
    return '$_temp0';
  }

  @override
  String downloadPlaylistQueued(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tracks queued for download',
      one: '1 track queued for download',
      zero: 'All tracks already downloaded',
    );
    return '$_temp0';
  }

  @override
  String get downloadsTitle => 'Downloads';

  @override
  String get downloadsTabSettings => 'Settings';

  @override
  String get downloadsTabQueue => 'Queue';

  @override
  String get downloadsTabDownloaded => 'Downloaded';

  @override
  String get downloadsQueueEmpty => 'No pending downloads';

  @override
  String get downloadsQueueEmptySubtitle =>
      'Download tracks from albums or playlists for offline listening.';

  @override
  String get downloadsDownloadedEmpty => 'No downloaded tracks';

  @override
  String get downloadsDownloadedEmptySubtitle =>
      'Downloaded tracks will appear here.';

  @override
  String get downloadsRemoveAction => 'Remove download';

  @override
  String get downloadsOpenFolderAction => 'Open downloaded folder';

  @override
  String get downloadsOpenFolderError =>
      'Could not open the downloaded folder.';

  @override
  String get downloadsRedownloadOriginal => 'Re-download in original quality';

  @override
  String get downloadsRedownloadOriginalSub =>
      'Replace with an untranscoded copy from server';

  @override
  String get downloadsRedownloadQueued => 'Queued for re-download';

  @override
  String get downloadsChangeQuality => 'Change Download Quality';

  @override
  String downloadsChangeQualityCurrent(String quality) {
    return 'Current: $quality';
  }

  @override
  String get downloadsCancelAction => 'Cancel download';

  @override
  String get downloadsClearCompleted => 'Clear completed';

  @override
  String get downloadsRetryFailed => 'Retry failed';

  @override
  String get downloadsStatusFailed => 'Failed';

  @override
  String get downloadsRetryAllFailed => 'Retry all failed';

  @override
  String get downloadsErrorLoadingQueue => 'Could not load download queue.';

  @override
  String get downloadsClearQueue => 'Clear queue';

  @override
  String get downloadsClearQueueConfirm =>
      'Remove all queued downloads? Active downloads will be cancelled.';

  @override
  String get downloadsQueueSearchHint => 'Search queue...';

  @override
  String get downloadsSearchHint => 'Search downloads...';

  @override
  String get downloadsCustomFolderTitle => 'Custom Folder';

  @override
  String get downloadsCustomFolderSubtitle =>
      'Store permanent downloads in a folder you choose. Existing downloads will be moved and renamed into artist folders.';

  @override
  String get downloadsCustomFolderUnsupported =>
      'Custom download folders are not available on this platform.';

  @override
  String get downloadsCustomFolderChooseAction => 'Choose folder';

  @override
  String get downloadsCustomFolderSaved => 'Download folder updated.';

  @override
  String get downloadsCustomFolderDisabled =>
      'Custom download folder disabled.';

  @override
  String get downloadsCustomFolderUpdating => 'Moving downloaded tracks...';

  @override
  String downloadsCustomFolderError(String message) {
    return 'Could not update download folder: $message';
  }

  @override
  String downloadsSearchNoResults(String query) {
    return 'No results for \"$query\"';
  }

  @override
  String get libraryDownloadedOnlyFilter => 'Downloaded';

  @override
  String get libraryDownloadedOnlyEmpty => 'No downloaded content';

  @override
  String get libraryDownloadedOnlyEmptySubtitle =>
      'Download albums or tracks to see them here.';

  @override
  String get libraryUnknownYear => 'Unknown year';

  @override
  String get cacheSettingsWifiOnlyDownloads => 'Download on Wi-Fi only';

  @override
  String get cacheSettingsWifiOnlyDownloadsSub =>
      'Pause downloads when not connected to Wi-Fi.';

  @override
  String get cacheSettingsAutoDownloadStarred => 'Auto-download liked';

  @override
  String get cacheSettingsAutoDownloadStarredSub =>
      'Queue liked albums and songs for download automatically.';

  @override
  String get cacheSettingsAutoDownloadCellularWarningTitle =>
      'Allow liked downloads on mobile data?';

  @override
  String get cacheSettingsAutoDownloadCellularWarning =>
      'Your liked library can use a large amount of storage and mobile data when Wi-Fi-only downloads are off.';

  @override
  String get cacheSettingsAutoDownloadCellularWarningContinue => 'Continue';

  @override
  String get cacheBadgeDownloaded => 'Downloaded';

  @override
  String get cacheBadgeCached => 'Cached';

  @override
  String get appearanceTitle => 'Appearance';

  @override
  String get appearanceThemeModeLabel => 'Theme Mode';

  @override
  String get appearanceThemeLight => 'Light';

  @override
  String get appearanceThemeDark => 'Dark';

  @override
  String get appearanceThemeOled => 'OLED';

  @override
  String get appearanceThemeSystem => 'Auto';

  @override
  String get appearanceLanguageLabel => 'Language';

  @override
  String get appearanceLanguageSystemDefault => 'System default';

  @override
  String get appearanceColorSchemeLabel => 'Color Scheme';

  @override
  String get appearanceColorSchemeSub =>
      'Choose a seed color for the app\'s color palette.';

  @override
  String get appearanceColorDefault => 'Default';

  @override
  String get appearanceColorCustom => 'Custom';

  @override
  String get appearanceColorPickerTitle => 'Pick a custom color';

  @override
  String get appearanceColorPickerSave => 'Save as preset';

  @override
  String get appearanceColorPickerApply => 'Apply';

  @override
  String get appearanceColorPresetSaved => 'Custom preset saved';

  @override
  String get appearanceColorPresetDeleted => 'Custom preset deleted';

  @override
  String get appearanceColorDeletePreset => 'Delete preset';

  @override
  String get appearanceColorDeletePresetConfirm =>
      'Delete this custom color preset?';

  @override
  String appearanceLongPressHint(Object label) {
    return '$label (long-press to delete)';
  }

  @override
  String get appearanceArtTintedLabel => 'Art-tinted Now Playing';

  @override
  String get appearanceArtTintedSub =>
      'Tint the Now Playing background with colours from the album art.';

  @override
  String get cacheSettingsCoverArtSection => 'Cover art cache';

  @override
  String get cacheSettingsCoverArtDescription =>
      'Cached album artwork images. Larger limits reduce network requests but use more storage.';

  @override
  String get cacheSettingsCoverArtMaxLabel => 'Maximum images';

  @override
  String cacheSettingsCoverArtMaxValue(int count) {
    return '$count images';
  }

  @override
  String get cacheSettingsCoverArtMaxSaved => 'Cover art cache limit updated.';

  @override
  String get cacheSettingsCoverArtRestart =>
      'Changes take effect after restarting the app.';

  @override
  String get cacheSettingsCoverArtUnlimitedLabel => 'No limit';

  @override
  String get cacheSettingsCoverArtUnlimitedSubtitle =>
      'Store all cover art on disk without restriction.';

  @override
  String get aboutTitle => 'About';

  @override
  String get aboutVersion => 'Version';

  @override
  String get aboutChangelog => 'What\'s New';

  @override
  String get aboutChangelogSub => 'See what changed in this version.';

  @override
  String get whatsNewTitle => 'What\'s New';

  @override
  String get changelogEmpty => 'No changelog entries yet.';

  @override
  String get aboutLicenses => 'Open-source licenses';

  @override
  String get aboutLicensesSub => 'View third-party software licenses.';

  @override
  String get privacyTitle => 'Privacy';

  @override
  String get privacySub =>
      'How Navis handles app data and optional service sharing.';

  @override
  String get aboutCodename => 'Cape Horn';

  @override
  String get aboutDataUsageTitle => 'Data Usage';

  @override
  String get aboutDataUsageSubtitle =>
      'Local network usage estimates by feature and network type.';

  @override
  String get aboutDataUsageToday => 'Today';

  @override
  String get aboutDataUsageSevenDays => 'Last 7 days';

  @override
  String get aboutDataUsageThirtyDays => 'Last 30 days';

  @override
  String get aboutDataUsageBreakdown => 'Last 7 days by feature';

  @override
  String get aboutDataUsageEmpty => 'No usage recorded yet.';

  @override
  String get aboutDataUsageLoading => 'Loading usage stats...';

  @override
  String get aboutDataUsageUnavailable => 'Usage stats unavailable.';

  @override
  String aboutDataUsageRequests(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count requests',
      one: '1 request',
      zero: 'No requests',
    );
    return '$_temp0';
  }

  @override
  String get aboutDataUsageReset => 'Reset usage stats';

  @override
  String get aboutDataUsageResetConfirmTitle => 'Reset usage stats?';

  @override
  String get aboutDataUsageResetConfirmMessage =>
      'This clears local network usage totals on this device.';

  @override
  String get aboutDataUsageResetCancel => 'Cancel';

  @override
  String get aboutDataUsageResetConfirmAction => 'Reset';

  @override
  String get aboutDataUsageResetComplete => 'Usage stats reset.';

  @override
  String get aboutDataUsageResetFailed => 'Could not reset usage stats.';

  @override
  String get aboutDataUsageNetworkWifi => 'Wi-Fi';

  @override
  String get aboutDataUsageNetworkMobile => 'Mobile';

  @override
  String get aboutDataUsageNetworkOffline => 'Offline';

  @override
  String get aboutDataUsageNetworkOther => 'Other network';

  @override
  String get aboutDataUsageCategoryAudioStreaming => 'Audio streaming';

  @override
  String get aboutDataUsageCategoryDownloads => 'Downloads';

  @override
  String get aboutDataUsageCategoryCoverArt => 'Cover art';

  @override
  String get aboutDataUsageCategoryLibrarySync => 'Library sync';

  @override
  String get aboutDataUsageCategoryLyrics => 'Lyrics';

  @override
  String get aboutDataUsageCategoryScrobbling => 'Scrobbling';

  @override
  String get aboutDataUsageCategoryRecommendations => 'Recommendations';

  @override
  String get aboutDataUsageCategoryUpdates => 'Updates';

  @override
  String get aboutDataUsageCategoryOtherApi => 'Other API';

  @override
  String get updateCheckTitle => 'Check for updates';

  @override
  String updateCheckSub(String version) {
    return 'Currently on $version. Tap to check now.';
  }

  @override
  String get updateAvailableTitle => 'Update available';

  @override
  String updateAvailableBody(String version) {
    return '$version is ready to download.';
  }

  @override
  String get updateDownload => 'Download';

  @override
  String get updateDismiss => 'Dismiss';

  @override
  String get updateUpToDate => 'Navis is up to date.';

  @override
  String get updateInstall => 'Install';

  @override
  String get updateRetry => 'Retry';

  @override
  String get updateReleaseNotes => 'Release notes';

  @override
  String updateDownloading(String version) {
    return 'Downloading $version…';
  }

  @override
  String get updateReadyToInstall => 'Download complete. Ready to install.';

  @override
  String get updateDownloadFailed => 'Download failed. Please try again.';

  @override
  String get updateApplyFailed => 'Could not apply the update automatically.';

  @override
  String get updateReadyToRestart =>
      'Download complete. Restart the app to apply the update.';

  @override
  String get updateRestartAndUpdate => 'Restart & Update';

  @override
  String get updateApplying => 'Applying update…';

  @override
  String get updateNoWriteAccess =>
      'Navis cannot update itself from this location. Please download manually.';

  @override
  String get updateSignatureMismatch =>
      'This update is signed with a different key than your installed version. Uninstall Navis, then install the new version manually.';

  @override
  String get updateDownloadManually => 'Download Manually';

  @override
  String get updatePlayStoreTitle => 'Update on Google Play';

  @override
  String updatePlayStoreBody(String version) {
    return '$version is available on Google Play. Update there to get the latest release.';
  }

  @override
  String get updateOpenPlayStore => 'Open in Play Store';

  @override
  String get updatePlayStoreFallbackNotice =>
      'Could not open Google Play. Opening the release page instead.';

  @override
  String get updateAutoCheckTitle => 'Automatically check for updates';

  @override
  String get updateAutoCheckSubtitle =>
      'Check for new releases on each app launch.';

  @override
  String get updatesSettingsSectionLabel => 'Updates';

  @override
  String get updateChannelTitle => 'Update channel';

  @override
  String get updateChannelStable => 'Stable';

  @override
  String get updateChannelBeta => 'Beta';

  @override
  String get updateChannelBetaDescription => 'Includes pre-release builds';

  @override
  String get updateChannelDialogTitle => 'Select update channel';

  @override
  String get appearancePagesSectionLabel => 'Page Visibility';

  @override
  String get appearanceShowRadioPageTitle => 'Show Radio Tab';

  @override
  String get appearanceShowRadioPageSubtitle =>
      'Show the Radio tab in the Library screen.';

  @override
  String get appearanceShowPlaylistsPageTitle => 'Show Playlists Tab';

  @override
  String get appearanceShowPlaylistsPageSubtitle =>
      'Show the Playlists tab in the Library screen.';

  @override
  String get appearanceShowArtistsPageTitle => 'Show Artists Tab';

  @override
  String get appearanceShowArtistsPageSubtitle =>
      'Show the Artists tab in the Library screen.';

  @override
  String get appearanceShowLikedPageTitle => 'Show Liked Tab';

  @override
  String get appearanceShowLikedPageSubtitle =>
      'Show the Liked tab in the Library screen.';

  @override
  String get appearanceGridDensityLabel => 'Grid Density';

  @override
  String get appearanceGridDensitySub =>
      'Number of columns in album and artist grids.';

  @override
  String get appearanceGridDensityAuto => 'Auto';

  @override
  String get appearanceGridDensityCompact => 'Compact';

  @override
  String get appearanceGridDensityCozy => 'Cozy';

  @override
  String get appearanceGridDensitySpaciousLabel => 'Spacious';

  @override
  String get appearanceCoverArtShapeLabel => 'Cover Art Shape';

  @override
  String get appearanceCoverArtShapeSubLabel => 'Library & Carousel Art';

  @override
  String get appearanceNpArtShapeLabel => 'Now Playing Art';

  @override
  String get appearanceArtistCardShapeLabel => 'Artist Card Art';

  @override
  String get shapeSquare => 'Square';

  @override
  String get shapeRounded => 'Rounded';

  @override
  String get shapeCircle => 'Circle';

  @override
  String get appearanceArtistViewModeLabel => 'Artist View Mode';

  @override
  String get appearanceArtistViewModeGrid => 'Grid';

  @override
  String get appearanceArtistViewModeList => 'List';

  @override
  String get appearanceHomeSectionsLabel => 'Home Sections';

  @override
  String get appearanceHomeSectionsSub =>
      'Drag to reorder, toggle to show or hide.';

  @override
  String get appearanceHomeDensityLabel => 'Home Density';

  @override
  String get appearanceHomeDensitySub =>
      'Choose spacing style for Home cards and lists.';

  @override
  String get appearanceHomeDensityComfortable => 'Comfortable';

  @override
  String get appearanceHomeDensityCompact => 'Compact';

  @override
  String get desktopNavbarSectionLabel => 'Desktop Navigation';

  @override
  String get desktopNavbarStyleLabel => 'Navigation Style';

  @override
  String get desktopNavbarStyleComfortable => 'Comfortable';

  @override
  String get desktopNavbarStyleCompact => 'Compact';

  @override
  String get desktopNavbarStyleIcons => 'Icons';

  @override
  String get desktopNavbarAutohideLabel => 'Autohide Sidebar';

  @override
  String get desktopNavbarAutohideSub =>
      'Sidebar slides away automatically; hover the left edge to reveal it.';

  @override
  String get desktopNavbarLockTooltip => 'Lock sidebar';

  @override
  String get desktopNavbarUnlockTooltip => 'Unlock sidebar';

  @override
  String get homeSectionContinueListening => 'Continue Listening';

  @override
  String get homeSectionRecentlyLikedAlbums => 'Recently Liked Albums';

  @override
  String get homeSectionLikedTracks => 'Liked Tracks';

  @override
  String get homeSectionRecentlyAdded => 'Recently Added';

  @override
  String get homeSectionRecentlyPlayed => 'Recently Played';

  @override
  String get homeSectionRandomAlbums => 'You Might Like';

  @override
  String get homeSectionMostPlayed => 'Most Played';

  @override
  String get homeSectionRecentlyPlayedTracks => 'Recently Played Tracks';

  @override
  String get homeSectionFrequentAlbums => 'Frequent Albums';

  @override
  String get homeSectionQuickActions => 'Quick Actions';

  @override
  String cacheSettingsCoverArtSizeLabel(String size) {
    return 'Storage used: $size';
  }

  @override
  String get cacheSettingsPrecacheTitle => 'Pre-cache all album art';

  @override
  String get cacheSettingsPrecacheSubtitle =>
      'Download artwork for every album to the device now. Only available when cover art cache has no limit.';

  @override
  String cacheSettingsPrecachingProgress(int done, int total) {
    return 'Caching $done of $total...';
  }

  @override
  String cacheSettingsPrecacheSuccess(int total) {
    return 'Done — cached $total album art image(s).';
  }

  @override
  String get serverSettingsSignOutConfirmTitle => 'Sign out';

  @override
  String get serverSettingsSignOutConfirmMessage =>
      'How would you like to handle your local library data?';

  @override
  String get serverSettingsConnectionInfoTitle => 'Connection info';

  @override
  String get audioMuseSettingsTitle => 'AudioMuse AI';

  @override
  String get audioMuseSettingsSubtitle =>
      'AI-powered smart queuing & discovery';

  @override
  String get audioMuseEnabledLabel => 'Enable AudioMuse';

  @override
  String get audioMuseEnabledSubtitle =>
      'Connect to an AudioMuse server for AI recommendations';

  @override
  String get audioMuseServerUrlLabel => 'Server URL';

  @override
  String get audioMuseServerUrlHint => 'https://audiomuse.example.com';

  @override
  String get audioMuseApiKeyLabel => 'API Key';

  @override
  String get audioMuseApiKeyHint => 'Optional — leave blank if not required';

  @override
  String get audioMuseTestConnection => 'Test connection';

  @override
  String audioMuseTestConnectionSuccess(String version) {
    return 'Connected to AudioMuse (v$version).';
  }

  @override
  String get audioMuseTestConnectionFailed =>
      'Could not connect to AudioMuse server.';

  @override
  String get audioMuseSimilarArtists => 'AI Similar Artists';

  @override
  String get audioMuseSimilarAlbums => 'You might also like';

  @override
  String get audioMuseSmartQueue => 'Smart Queue';

  @override
  String get audioMuseSmartQueueActive => 'AI auto-queue is active';

  @override
  String get audioMuseSmartQueueStopped => 'AI auto-queue stopped';

  @override
  String audioMuseSmartQueueQueued(int count) {
    return '$count AI-recommended tracks queued.';
  }

  @override
  String get audioMuseGenerateMix => 'Create AI Mix';

  @override
  String audioMuseGenerateMixSeed(String seedType) {
    return 'Generate a mix based on this $seedType';
  }

  @override
  String audioMuseMixGenerated(int count) {
    return 'AI Mix created — $count tracks queued.';
  }

  @override
  String get audioMuseMixFailed =>
      'Could not generate AI mix. Try again later.';

  @override
  String get audioMuseNotConfigured =>
      'AudioMuse is not configured. Set it up in Settings.';

  @override
  String get audioMuseConnectionSection => 'Connection';

  @override
  String get audioMuseDisabledHint =>
      'Enable AudioMuse above to configure the server.';

  @override
  String get smartQueueTitle => 'Smart Queues';

  @override
  String get smartQueueSubtitle => 'AI-powered queuing based on sonic analysis';

  @override
  String get smartQueueButton => 'Smart Queue';

  @override
  String get smartQueueActive => 'Smart Queue active';

  @override
  String get smartQueueStopped => 'Smart Queue stopped';

  @override
  String smartQueueStarted(int count) {
    return '$count tracks queued via Smart Queue.';
  }

  @override
  String get smartQueueUnsupported =>
      'Smart Queues require the AudioMuse plugin on your server.';

  @override
  String get smartQueueError =>
      'Smart Queue encountered an error. Please try again.';

  @override
  String get smartQueueSteadyVibes => 'Steady Vibes';

  @override
  String get smartQueueSteadyVibesDesc =>
      'Consistent mood — stays close to the original feel';

  @override
  String get smartQueueDiscoveryMix => 'Discovery Mix';

  @override
  String get smartQueueDiscoveryMixDesc =>
      'Explore new artists with maximum variety';

  @override
  String get smartQueueDeepDive => 'Deep Dive';

  @override
  String get smartQueueDeepDiveDesc =>
      'Stay immersed in the same artist and style';

  @override
  String get smartQueueEnergyFlow => 'Energy Flow';

  @override
  String get smartQueueEnergyFlowDesc =>
      'Let the mood gradually evolve track by track';

  @override
  String get songStatusQueued => 'Queued for download';

  @override
  String get songStatusDownloading => 'Downloading…';

  @override
  String get songStatusDownloaded => 'Downloaded';

  @override
  String get songStatusCachedTooltip =>
      'Temporarily cached — will be removed when cache fills up or when the track is downloaded';

  @override
  String get downloadsRemoveConfirmTitle => 'Remove download?';

  @override
  String get downloadsRemoveConfirmContent =>
      'The downloaded file will be permanently deleted.';

  @override
  String get deleteDownloadAction => 'Delete download';

  @override
  String get libraryAlbumMenuPlay => 'Play album';

  @override
  String get libraryAlbumMenuAddToQueue => 'Add to queue';

  @override
  String get libraryAlbumMenuDownload => 'Download album';

  @override
  String get libraryAlbumPlayQueued => 'Album queued to play';

  @override
  String get libraryAlbumAddedToQueue => 'Album added to queue';

  @override
  String get actionLike => 'Like';

  @override
  String get actionLiked => 'Liked';

  @override
  String get remoteSourceActionUnavailable =>
      'Not available for remote tracks.';

  @override
  String get remoteSourceInstantMixUnavailable =>
      'Instant Mix requires a locally scanned track.';

  @override
  String get commonSave => 'Save';

  @override
  String get commonDelete => 'Delete';

  @override
  String get commonRename => 'Rename';

  @override
  String get commonRemove => 'Remove';

  @override
  String get commonReorder => 'Reorder';

  @override
  String get matchFlowTitle => 'Match Flow';

  @override
  String get matchFlowPlaybackSettingsSubtitle =>
      'Expand a selected master song into a saved local playback flow.';

  @override
  String get matchFlowManageTitle => 'Manage Match Flows';

  @override
  String get matchFlowCreateAction => 'New Flow';

  @override
  String get matchFlowEmptyTitle => 'No Match Flows yet';

  @override
  String get matchFlowEmptySubtitle =>
      'Create a flow, choose a master song, then add the songs that should follow it.';

  @override
  String matchFlowLoadError(String error) {
    return 'Could not load Match Flow: $error';
  }

  @override
  String matchFlowSaveError(String error) {
    return 'Could not save Match Flow: $error';
  }

  @override
  String matchFlowSongCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count songs',
      one: '1 song',
      zero: 'No songs',
    );
    return '$_temp0';
  }

  @override
  String get matchFlowContentsTitle => 'Flow Contents';

  @override
  String get matchFlowExpandContents => 'Expand Flow Contents';

  @override
  String get matchFlowCollapseContents => 'Collapse Flow Contents';

  @override
  String get matchFlowNoSongs => 'Add a song to set the master.';

  @override
  String get matchFlowAddSongAction => 'Add song';

  @override
  String get matchFlowAddSongTitle => 'Add song';

  @override
  String get matchFlowSearchHint => 'Search songs';

  @override
  String get matchFlowNoSearchResults => 'No songs found';

  @override
  String get matchFlowRenameTitle => 'Rename flow';

  @override
  String get matchFlowNameLabel => 'Flow name';

  @override
  String get matchFlowDeleteTitle => 'Delete flow?';

  @override
  String matchFlowDeleteMessage(String name) {
    return 'Delete “$name” and its song order?';
  }

  @override
  String get matchFlowMasterLabel => 'Master';

  @override
  String matchFlowUnresolvedSong(String songId) {
    return 'Unresolved song $songId';
  }

  @override
  String matchFlowSongAdded(String title) {
    return 'Added $title.';
  }
}
