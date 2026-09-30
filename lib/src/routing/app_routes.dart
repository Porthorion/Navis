/// The single source of truth for Navis route locations.
///
/// Feature code never writes route strings: it asks [NavService] to navigate,
/// and [NavService] builds locations here. [app_router.dart] declares its
/// routes from the same path segments so the two cannot drift apart.
library;

/// The persistent shell branches, in the order the router declares them.
///
/// The branch index is the enum index; the visible destination order in the
/// shell is the same.
enum ShellBranch {
  home(AppRoutes.home),
  library(AppRoutes.library),
  search(AppRoutes.search),
  settings(AppRoutes.settings);

  const ShellBranch(this.rootLocation);

  /// The branch's root location.
  final String rootLocation;

  /// Branch for a shell index, clamped to a valid branch.
  static ShellBranch fromIndex(int index) =>
      ShellBranch.values[index.clamp(0, ShellBranch.values.length - 1)];
}

/// Pages under Settings that can be opened directly.
enum SettingsPage {
  server(AppRoutes.settingsServerSegment),
  cache(AppRoutes.settingsCacheSegment),
  downloads(AppRoutes.settingsDownloadsSegment),
  sync(AppRoutes.settingsSyncSegment),
  playback(AppRoutes.settingsPlaybackSegment),
  equalizer(AppRoutes.settingsEqualizerSegment),
  appearance(AppRoutes.settingsAppearanceSegment),
  about(AppRoutes.settingsAboutSegment),
  desktopWindow(AppRoutes.settingsDesktopWindowSegment),
  shortcuts(AppRoutes.settingsShortcutsSegment),
  unavailableItems(AppRoutes.settingsUnavailableItemsSegment);

  const SettingsPage(this.segment);

  final String segment;

  String get location => '${AppRoutes.settings}/$segment';

  /// Pages that only exist in the desktop runtime.
  bool get desktopOnly =>
      this == SettingsPage.desktopWindow || this == SettingsPage.shortcuts;
}

abstract final class AppRoutes {
  // ---------------------------------------------------------------------------
  // Top-level flows
  // ---------------------------------------------------------------------------
  static const login = '/login';
  static const initialSync = '/initial-sync';
  static const libraryRebuild = '/library-rebuild';
  static const onboarding = '/onboarding';

  /// Query flag that opens onboarding as a review from Settings.
  static const onboardingReviewParam = 'review';

  static String get onboardingReview =>
      _withQuery(onboarding, <String, String>{onboardingReviewParam: '1'});

  // ---------------------------------------------------------------------------
  // Shell branch roots
  // ---------------------------------------------------------------------------
  static const home = '/';
  static const library = '/library';
  static const search = '/search';
  static const settings = '/settings';

  // ---------------------------------------------------------------------------
  // Library children (path segments relative to [library])
  // ---------------------------------------------------------------------------
  static const artistSegment = 'artists/:id';
  static const artistTopTracksSegment = 'top-tracks';
  static const albumSegment = 'albums/:id';
  static const playlistSegment = 'playlists/:id';
  static const listenBrainzSegment = 'listenbrainz/:sourcePatch';
  static const likedArtistsSegment = 'liked-artists';
  static const likedAlbumsSegment = 'liked-albums';

  /// Query parameter naming the Library section shown at [library].
  static const librarySectionParam = 'section';

  /// The Library root showing the section named [sectionName].
  static String librarySection(String sectionName) =>
      _withQuery(library, <String, String>{librarySectionParam: sectionName});

  static String album(String id) => '$library/albums/${_encode(id)}';
  static String artist(String id) => '$library/artists/${_encode(id)}';
  static String artistTopTracks(String id) =>
      '${artist(id)}/$artistTopTracksSegment';
  static String playlist(String id) => '$library/playlists/${_encode(id)}';
  static String listenBrainzWeekly(String sourcePatch) =>
      '$library/listenbrainz/${_encode(sourcePatch)}';
  static const likedArtists = '$library/$likedArtistsSegment';
  static const likedAlbums = '$library/$likedAlbumsSegment';

  // ---------------------------------------------------------------------------
  // Settings children (path segments relative to [settings])
  // ---------------------------------------------------------------------------
  static const settingsServerSegment = 'server';
  static const settingsCacheSegment = 'cache';
  static const settingsDownloadsSegment = 'downloads';
  static const settingsSyncSegment = 'sync';
  static const settingsPlaybackSegment = 'playback';
  static const settingsEqualizerSegment = 'equalizer';
  static const settingsAppearanceSegment = 'appearance';
  static const settingsAboutSegment = 'about';
  static const settingsDesktopWindowSegment = 'desktop-window';
  static const settingsShortcutsSegment = 'shortcuts';
  static const settingsUnavailableItemsSegment = 'unavailable-items';
  static const matchFlowSegment = 'match-flow';
  static const matchFlowSearchSegment = ':flowId/search';
  static const changelogSegment = 'changelog';
  static const privacySegment = 'privacy';

  /// Retired Settings paths that still redirect to Configuration.
  static const retiredSettingsSegments = <String>[
    'group-listening',
    'external-services',
  ];

  static String get equalizer => SettingsPage.equalizer.location;
  static String get unavailableItems => SettingsPage.unavailableItems.location;
  static String get matchFlow =>
      '${SettingsPage.playback.location}/$matchFlowSegment';
  static String matchFlowSearch(String flowId) =>
      '$matchFlow/${_encode(flowId)}/search';
  static String get changelog =>
      '${SettingsPage.about.location}/$changelogSegment';
  static String get privacy => '${SettingsPage.about.location}/$privacySegment';

  static String _encode(String segment) => Uri.encodeComponent(segment);

  static String _withQuery(String path, Map<String, String> query) =>
      Uri(path: path, queryParameters: query).toString();
}
