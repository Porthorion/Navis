import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/equalizer/presentation/eq_screen.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/routing/navigation_history_provider.dart';

/// Route configuration for an album opened from an interactive surface.
///
/// Desktop and ordinary mobile album pages use a fast, composed-page fade.
/// Compact mobile landscape preserves its shared-artwork Hero.
@immutable
class AlbumDetailRouteRequest {
  const new({this.openingHeroTag, this.fadeOnly = false});

  final String? openingHeroTag;
  final bool fadeOnly;
}

/// Tracks the last back-press timestamp for double-back-to-exit.
DateTime? _lastBackPress;

/// Centralised navigation helpers that guarantee a consistent UX:
///
/// * Collapsing the player sheet before cross-screen navigation.
/// * Using `push` for contextual drill-in and `go` for explicit replacement.
/// * Dismissing shell-managed player overlays in strict top-first order.
abstract final class NavService {
  // ---------------------------------------------------------------------------
  // Library
  // ---------------------------------------------------------------------------

  /// Open an album detail from the current context, preserving back.
  ///
  /// [name] and [artistName] name an album the library may not hold yet (a
  /// remote album), for its page to show while it loads and to search for if
  /// the server cannot provide it.
  static void openAlbumDetail(
    BuildContext context,
    WidgetRef ref,
    String albumId, {
    String? heroTag,
    String? name,
    String? artistName,
  }) {
    _prepareForNavigation(context, ref);
    final normalizedHeroTag = heroTag?.trim();
    final adaptiveContext = resolveAdaptiveContextFor(context);
    final fadeOnly =
        adaptiveContext.desktopRuntime ||
        !adaptiveContext.useCompactWideLandscape;
    final request = AlbumDetailRouteRequest(
      // The page fades in as one already-composed surface, so it must not
      // pair with the tapped card's Hero during the route change.
      openingHeroTag:
          fadeOnly || normalizedHeroTag == null || normalizedHeroTag.isEmpty
          ? null
          : normalizedHeroTag,
      fadeOnly: fadeOnly,
    );
    _navigateVisibly(
      context,
      ref,
      (router) => unawaited(
        router.push<void>(
          AppRoutes.album(albumId, name: name, artistName: artistName),
          extra: request,
        ),
      ),
    );
  }

  /// Open an artist detail from the current context, preserving back.
  ///
  /// [name] names an artist the library may not hold yet (a remote artist),
  /// for its page to show while it loads and to search for if the server
  /// cannot provide it.
  static void openArtistDetail(
    BuildContext context,
    WidgetRef ref,
    String artistId, {
    String? name,
  }) {
    _drillIn(context, ref, AppRoutes.artist(artistId, name: name));
  }

  /// Open an artist's virtual top-tracks playlist from the current context.
  static void openArtistTopTracksPlaylist(
    BuildContext context,
    WidgetRef ref,
    String artistId,
  ) {
    _drillIn(context, ref, AppRoutes.artistTopTracks(artistId));
  }

  /// The Library playlist id of Home's Trending Now, which opens its page.
  static const String trendingPlaylistId = 'virtual:trending:deezer';

  /// Open a playlist detail from the current context, preserving back.
  static void openPlaylistDetail(
    BuildContext context,
    WidgetRef ref,
    String playlistId,
  ) {
    if (playlistId == trendingPlaylistId) {
      openTrending(context, ref);
      return;
    }
    const virtualPrefix = 'virtual:listenbrainz:';
    if (playlistId.startsWith(virtualPrefix)) {
      openListenBrainzWeeklyDetail(
        context,
        ref,
        playlistId.substring(virtualPrefix.length),
      );
      return;
    }
    _drillIn(context, ref, AppRoutes.playlist(playlistId));
  }

  /// Open a virtual ListenBrainz weekly playlist detail from Home.
  static void openListenBrainzWeeklyDetail(
    BuildContext context,
    WidgetRef ref,
    String sourcePatch,
  ) {
    final normalized = sourcePatch.trim();
    if (normalized.isEmpty) {
      return;
    }
    _drillIn(context, ref, AppRoutes.listenBrainzWeekly(normalized));
  }

  /// Open Home's Trending Now virtual playlist.
  static void openTrending(BuildContext context, WidgetRef ref) {
    _drillIn(context, ref, AppRoutes.trending);
  }

  /// Show a Library section, replacing the Library tab's pages.
  ///
  /// The section is part of the Library location, so returning to the tab,
  /// desktop history and diagnostics all restore it.
  static void openLibrarySection(
    BuildContext context,
    WidgetRef ref,
    LibrarySection section,
  ) {
    clearExitPrompt();
    _prepareForNavigation(context, ref);
    ref.read(librarySectionProvider.notifier).setSection(section);
    _navigateVisibly(
      context,
      ref,
      (router) => router.go(AppRoutes.librarySection(section.name)),
    );
  }

  /// Keep the Library location in step with a section chosen inside the
  /// Library page (a tab swipe), without other navigation side effects.
  static void recordLibrarySection(
    BuildContext context,
    LibrarySection section,
  ) {
    final router = GoRouter.maybeOf(context);
    if (router == null) {
      return;
    }
    final uri = router.state.uri;
    if (uri.path != AppRoutes.library ||
        uri.queryParameters[AppRoutes.librarySectionParam] == section.name) {
      return;
    }
    router.go(AppRoutes.librarySection(section.name));
  }

  /// The Library section named by [uri], when it is the Library root.
  static LibrarySection? librarySectionForLocation(Uri uri) {
    if (uri.path != AppRoutes.library) {
      return null;
    }
    final name = uri.queryParameters[AppRoutes.librarySectionParam];
    for (final section in LibrarySection.values) {
      if (section.name == name) {
        return section;
      }
    }
    return null;
  }

  /// Open the full list of liked albums from the current context.
  static void openLikedAlbums(BuildContext context, WidgetRef ref) {
    _drillIn(context, ref, AppRoutes.likedAlbums);
  }

  /// Open the full list of liked artists from the current context.
  static void openLikedArtists(BuildContext context, WidgetRef ref) {
    _drillIn(context, ref, AppRoutes.likedArtists);
  }

  /// Leave a detail page whose entity is no longer available and show the
  /// Library tab.
  ///
  /// The page is popped from the tab it was opened in, so returning to that
  /// tab later does not reveal it again.
  static void returnToLibrary(BuildContext context, WidgetRef ref) {
    clearExitPrompt();
    _prepareForNavigation(context, ref);
    final router = GoRouter.of(context);
    final shell = StatefulNavigationShell.maybeOf(context);
    if (router.canPop()) {
      router.pop();
    }
    if (shell == null) {
      router.go(AppRoutes.library);
      return;
    }
    if (shell.currentIndex == ShellBranch.library.index) {
      return;
    }
    // Let the pop settle into the origin branch before switching away from
    // it; switching in the same frame would store the stale stack.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      shell.goBranch(ShellBranch.library.index);
    });
  }

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  /// Open a Settings page from the current context, preserving back.
  static void openSettingsPage(
    BuildContext context,
    WidgetRef ref,
    SettingsPage page,
  ) {
    if (page == SettingsPage.equalizer) {
      openEqualizer(context, ref);
      return;
    }
    _drillIn(context, ref, page.location);
  }

  /// Open the unavailable-items review screen.
  static void openUnavailableItems(BuildContext context, WidgetRef ref) {
    openSettingsPage(context, ref, SettingsPage.unavailableItems);
  }

  /// Open Appearance settings, e.g. from a recovery state.
  static void openAppearanceSettings(BuildContext context, WidgetRef ref) {
    openSettingsPage(context, ref, SettingsPage.appearance);
  }

  /// Open the Match Flow list from Playback settings.
  static void openMatchFlow(BuildContext context, WidgetRef ref) {
    _drillIn(context, ref, AppRoutes.matchFlow);
  }

  /// Open the song search for one Match Flow.
  static void openMatchFlowSearch(
    BuildContext context,
    WidgetRef ref,
    String flowId,
  ) {
    _drillIn(context, ref, AppRoutes.matchFlowSearch(flowId));
  }

  /// Open the full changelog from the current context, preserving back,
  /// optionally focused on [version].
  ///
  /// Takes no [WidgetRef] so plain builders (such as the Home discovery card's
  /// callbacks) can open it.
  static void openChangelog(BuildContext context, {String? version}) {
    clearExitPrompt();
    _dismissTransientSurfaces(context);
    ProviderScope.containerOf(
      context,
      listen: false,
    ).read(playerOverlayStackProvider.notifier).clear();
    unawaited(
      context.push<void>(
        Uri(
          path: AppRoutes.changelog,
          queryParameters: version == null ? null : {'version': version},
        ).toString(),
      ),
    );
  }

  /// Open the privacy page from About.
  static void openPrivacy(BuildContext context, WidgetRef ref) {
    _drillIn(context, ref, AppRoutes.privacy);
  }

  /// Re-run onboarding as a review from Settings.
  static void openOnboardingReview(BuildContext context, WidgetRef ref) {
    _drillIn(context, ref, AppRoutes.onboardingReview);
  }

  /// Open the full Equalizer page, dismissing popups and player overlays so
  /// the page is visible.
  ///
  /// Closing the page returns the person to where they started: an expanded
  /// Now Playing is re-expanded and Mini Player is restored, as long as they
  /// came straight back rather than navigating somewhere else. The route lives
  /// in the Settings branch, which the desktop Mini Player does not render, so
  /// Mini Player first returns to the full view; when the window cannot leave
  /// Mini Player, the page is shown directly over it.
  static void openEqualizer(BuildContext context, WidgetRef ref) {
    clearExitPrompt();
    final router = GoRouter.of(context);
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    final container = ProviderScope.containerOf(context, listen: false);
    final window = ref.read(desktopWindowControllerProvider);
    final restoreNowPlaying = ref
        .read(playerOverlayStackProvider)
        .contains(PlayerOverlayRoute.nowPlaying);
    final restoreMiniPlayer = window.isMiniPlayerMode;
    final origin = router.state.uri.toString();
    _prepareForNavigation(context, ref);

    void restoreOrigin(Object? _) {
      if (router.state.uri.toString() != origin) {
        return;
      }
      if (restoreMiniPlayer) {
        final current = container.read(desktopWindowControllerProvider);
        if (!current.isMiniPlayerMode) {
          unawaited(current.setMiniPlayerMode(true));
        }
      } else if (restoreNowPlaying) {
        container.read(playerOverlayStackProvider.notifier).expand();
      }
    }

    if (!window.isMiniPlayerMode) {
      unawaited(router.push<void>(AppRoutes.equalizer).then(restoreOrigin));
      return;
    }
    if (!window.desktopViewAvailable) {
      // Popping this route reveals the Mini Player again.
      rootNavigator.push(
        MaterialPageRoute<void>(builder: (_) => const EqualizerScreen()),
      );
      return;
    }
    unawaited(
      window
          .setMiniPlayerMode(false)
          .then((_) => router.push<void>(AppRoutes.equalizer))
          .then(restoreOrigin),
    );
  }

  /// Leave the Equalizer page after persisting in-progress edits, returning
  /// to wherever it was opened from (Settings when there is no history).
  static Future<void> closeEqualizer(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final router = GoRouter.of(context);
    await ref.read(equalizerProvider.notifier).flushEdits();
    _backWith(router, fallback: AppRoutes.settings);
  }

  /// Leave the current page, returning to wherever it was opened from.
  ///
  /// Every page back button uses this. When the page has no history (a deep
  /// link or a restored location), [fallback] is shown instead.
  static void back(BuildContext context, {String fallback = AppRoutes.home}) {
    dismissKeyboard(context);
    _backWith(GoRouter.of(context), fallback: fallback);
  }

  static void _backWith(GoRouter router, {required String fallback}) {
    clearExitPrompt();
    if (router.canPop()) {
      router.pop();
    } else {
      router.go(fallback);
    }
  }

  /// Navigate to the search screen and pre-fill the query.
  ///
  /// Useful for radio "search for this artist / song" flows.
  static void openSearch(
    BuildContext context,
    WidgetRef ref,
    String query, {
    SearchResultType? filter,
  }) {
    clearExitPrompt();
    _prepareForNavigation(context, ref);
    ref.read(searchFilterProvider.notifier).select(filter);
    ref.read(searchQueryProvider.notifier).submit(query);
    final trimmed = query.trim();
    if (trimmed.isNotEmpty) {
      unawaited(
        ref.read(navisDatabaseProvider).historyDao.saveSearchQuery(trimmed),
      );
    }
    _navigateVisibly(context, ref, (router) => router.go(AppRoutes.search));
  }

  /// Switch to a shell tab.
  ///
  /// Re-selecting the current tab with [initialLocation] returns that tab to
  /// its root.
  static void switchTab(
    BuildContext context,
    WidgetRef ref,
    StatefulNavigationShell navigationShell,
    ShellBranch branch, {
    bool initialLocation = false,
  }) {
    clearExitPrompt();
    _prepareForNavigation(context, ref);
    // Menus opened from a page live on that tab's navigator, which the shell
    // context above does not reach.
    final tabNavigator = navigationShell
        .route
        .branches[navigationShell.currentIndex]
        .navigatorKey
        .currentState;
    if (tabNavigator != null) {
      _dismissPopupRoutes(tabNavigator);
    }
    navigationShell.goBranch(branch.index, initialLocation: initialLocation);
  }

  // ---------------------------------------------------------------------------
  // Player helpers
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Desktop
  // ---------------------------------------------------------------------------

  /// Moves through desktop navigation history (mouse Back/Forward, the
  /// Back/Forward shortcuts and the workspace header buttons).
  static Future<void> navigateHistory(
    WidgetRef ref, {
    required bool forward,
  }) async {
    // Mini Player has no pages to move between.
    if (ref.read(desktopWindowControllerProvider).isMiniPlayerMode) {
      return;
    }
    final history = ref.read(navigationHistoryProvider.notifier);
    if (forward) {
      history.navigateForward();
    } else {
      history.navigateBack();
    }
  }

  /// Show the playback queue on the shell-managed player overlay stack.
  static void showQueue(BuildContext context, WidgetRef ref) {
    clearExitPrompt();
    dismissKeyboard(context);
    ref.read(playerOverlayStackProvider.notifier).showQueue();
  }

  // ---------------------------------------------------------------------------
  // Smart back-button behaviour
  // ---------------------------------------------------------------------------

  /// Handles system back (Android back gesture / button) with the following
  /// priority chain:
  ///
  /// **Important:** Navigator-owned modal routes (dialogs, overflow menus,
  /// etc.) are popped before this method runs. The shell route only calls this
  /// when it is the visible top route.
  ///
  /// 1. **Shell player overlay stack** → dismiss top-most player surface.
  /// 2. **GoRouter can pop** (sub-route within a branch) → pop it.
  /// 3. **Not on Home tab** → switch to Home.
  /// 4. **Home tab root** → require double-tap to exit.
  static void handleSystemBack({
    required WidgetRef ref,
    required BuildContext context,
    required StatefulNavigationShell navigationShell,
    AppNoticeController? noticeController,
  }) {
    // 1. Dismiss the top-most shell-managed player surface.
    if (ref.read(playerOverlayStackProvider.notifier).dismissTop()) {
      dismissKeyboard(context);
      clearExitPrompt();
      return;
    }

    // 2. Pop sub-route (e.g. album detail → library root)
    if (GoRouter.of(context).canPop()) {
      clearExitPrompt();
      context.pop();
      return;
    }

    // 3. Go home if we're on another tab's root
    if (navigationShell.currentIndex != ShellBranch.home.index) {
      switchTab(context, ref, navigationShell, ShellBranch.home);
      return;
    }

    // 4. We're at Home root — require double-tap to exit
    final now = DateTime.now();
    if (_lastBackPress != null &&
        now.difference(_lastBackPress!).inMilliseconds < 2000) {
      unawaited(SystemNavigator.pop());
    } else {
      _lastBackPress = now;
      final controller = noticeController ?? AppNoticeScope.maybeOf(context);
      if (controller != null) {
        controller.show(
          message: AppLocalizations.of(context)!.navigationBackToExitPrompt,
        );
      }
    }
  }

  /// Clears any pending double-back-to-exit window after real navigation.
  static void clearExitPrompt() {
    _lastBackPress = null;
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  /// Push [location] on the current tab, preserving back.
  static void _drillIn(BuildContext context, WidgetRef ref, String location) {
    clearExitPrompt();
    _prepareForNavigation(context, ref);
    _navigateVisibly(
      context,
      ref,
      (router) => unawaited(router.push<void>(location)),
    );
  }

  /// Runs [navigate] where the person can see it.
  ///
  /// Mini Player shows no pages, so links followed from it (such as the
  /// album or artist of the playing track) first return to Desktop View. When
  /// the window is too small for Desktop View the link does nothing.
  static void _navigateVisibly(
    BuildContext context,
    WidgetRef ref,
    void Function(GoRouter router) navigate,
  ) {
    // Captured now: the Mini Player surface, and with it [context], goes
    // away when the window leaves Mini Player.
    final router = GoRouter.of(context);
    final window = ref.read(desktopWindowControllerProvider);
    if (!window.isMiniPlayerMode) {
      navigate(router);
      return;
    }
    if (!window.desktopViewAvailable) {
      return;
    }
    unawaited(window.setMiniPlayerMode(false).then((_) => navigate(router)));
  }

  /// Dismiss popup routes and clear the shell's own player overlay stack.
  static void _prepareForNavigation(BuildContext context, WidgetRef ref) {
    _dismissTransientSurfaces(context);
    // Reset shell-managed player overlays so navigation starts clean.
    ref.read(playerOverlayStackProvider.notifier).clear();
  }

  /// Dismiss the keyboard and any popup routes above the current page.
  static void _dismissTransientSurfaces(BuildContext context) {
    dismissKeyboard(context);

    _dismissPopupRoutes(Navigator.of(context));
    final rootNav = Navigator.of(context, rootNavigator: true);
    if (rootNav != Navigator.of(context)) {
      _dismissPopupRoutes(rootNav);
    }
  }

  static void _dismissPopupRoutes(NavigatorState navigator) {
    navigator.popUntil((route) => route is! PopupRoute);
  }

  /// Dismiss the on-screen keyboard and clear any active text focus.
  static void dismissKeyboard([BuildContext? context]) {
    if (context != null) {
      FocusScope.of(context).unfocus();
    }
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
  }
}
