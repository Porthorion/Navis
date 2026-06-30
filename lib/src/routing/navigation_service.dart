import 'dart:async';

import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';

/// The navigation intent behind a [NavService] operation.
///
/// These values are not persisted. They make call sites explicit about whether
/// a navigation should preserve the current route stack, replace it, switch
/// shell tabs, or show a transient overlay.
enum AppNavigationIntent { drillIn, replace, switchTab, modal }

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
  static void openAlbumDetail(
    BuildContext context,
    WidgetRef ref,
    String albumId,
  ) {
    _prepareForNavigation(context, ref, AppNavigationIntent.drillIn);
    unawaited(context.push<void>('/library/albums/$albumId'));
  }

  /// Open an artist detail from the current context, preserving back.
  static void openArtistDetail(
    BuildContext context,
    WidgetRef ref,
    String artistId,
  ) {
    _prepareForNavigation(context, ref, AppNavigationIntent.drillIn);
    unawaited(context.push<void>('/library/artists/$artistId'));
  }

  /// Open an artist's virtual top-tracks playlist from the current context.
  static void openArtistTopTracksPlaylist(
    BuildContext context,
    WidgetRef ref,
    String artistId,
  ) {
    _prepareForNavigation(context, ref, AppNavigationIntent.drillIn);
    unawaited(context.push<void>('/library/artists/$artistId/top-tracks'));
  }

  /// Open a playlist detail from the current context, preserving back.
  static void openPlaylistDetail(
    BuildContext context,
    WidgetRef ref,
    String playlistId,
  ) {
    const virtualPrefix = 'virtual:listenbrainz:';
    if (playlistId.startsWith(virtualPrefix)) {
      openListenBrainzWeeklyDetail(
        context,
        ref,
        playlistId.substring(virtualPrefix.length),
      );
      return;
    }
    _prepareForNavigation(context, ref, AppNavigationIntent.drillIn);
    unawaited(context.push<void>('/library/playlists/$playlistId'));
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
    _prepareForNavigation(context, ref, AppNavigationIntent.drillIn);
    unawaited(
      context.push<void>(
        '/library/listenbrainz/${Uri.encodeComponent(normalized)}',
      ),
    );
  }

  /// Replace the current route with an album detail.
  static void replaceWithAlbumDetail(
    BuildContext context,
    WidgetRef ref,
    String albumId,
  ) {
    clearExitPrompt();
    _prepareForNavigation(context, ref, AppNavigationIntent.replace);
    context.go('/library/albums/$albumId');
  }

  /// Replace the current route with an artist detail.
  static void replaceWithArtistDetail(
    BuildContext context,
    WidgetRef ref,
    String artistId,
  ) {
    clearExitPrompt();
    _prepareForNavigation(context, ref, AppNavigationIntent.replace);
    context.go('/library/artists/$artistId');
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
    _prepareForNavigation(context, ref, AppNavigationIntent.replace);
    ref.read(searchFilterProvider.notifier).select(filter);
    ref.read(searchQueryProvider.notifier).submit(query);
    context.go('/search');
  }

  /// Switch to the Home tab.
  static void switchToHome(
    BuildContext context,
    WidgetRef ref,
    StatefulNavigationShell navigationShell, {
    int branchIndex = 0,
    bool initialLocation = false,
  }) {
    _switchToBranch(
      context,
      ref,
      navigationShell,
      branchIndex,
      initialLocation: initialLocation,
    );
  }

  /// Switch to the Library tab.
  static void switchToLibrary(
    BuildContext context,
    WidgetRef ref,
    StatefulNavigationShell navigationShell, {
    int branchIndex = 1,
    bool initialLocation = false,
  }) {
    _switchToBranch(
      context,
      ref,
      navigationShell,
      branchIndex,
      initialLocation: initialLocation,
    );
  }

  /// Switch to the Search tab.
  static void switchToSearch(
    BuildContext context,
    WidgetRef ref,
    StatefulNavigationShell navigationShell, {
    int branchIndex = 2,
    bool initialLocation = false,
  }) {
    _switchToBranch(
      context,
      ref,
      navigationShell,
      branchIndex,
      initialLocation: initialLocation,
    );
  }

  /// Switch to the Settings tab.
  static void switchToSettings(
    BuildContext context,
    WidgetRef ref,
    StatefulNavigationShell navigationShell, {
    int branchIndex = 3,
    bool initialLocation = false,
  }) {
    _switchToBranch(
      context,
      ref,
      navigationShell,
      branchIndex,
      initialLocation: initialLocation,
    );
  }

  // ---------------------------------------------------------------------------
  // Player helpers
  // ---------------------------------------------------------------------------

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
    required int homeBranchIndex,
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
    if (navigationShell.currentIndex != homeBranchIndex) {
      clearExitPrompt();
      navigationShell.goBranch(homeBranchIndex);
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
        controller.show(message: 'Press back again to exit');
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

  static void _switchToBranch(
    BuildContext context,
    WidgetRef ref,
    StatefulNavigationShell navigationShell,
    int branchIndex, {
    required bool initialLocation,
  }) {
    _prepareForNavigation(context, ref, AppNavigationIntent.switchTab);
    navigationShell.goBranch(branchIndex, initialLocation: initialLocation);
  }

  /// Dismiss popup routes and clear the shell's own player overlay stack.
  static void _prepareForNavigation(
    BuildContext context,
    WidgetRef ref,
    AppNavigationIntent intent,
  ) {
    dismissKeyboard(context);

    _dismissPopupRoutes(Navigator.of(context));
    final rootNav = Navigator.of(context, rootNavigator: true);
    if (rootNav != Navigator.of(context)) {
      _dismissPopupRoutes(rootNav);
    }

    // Reset shell-managed player overlays so navigation starts clean.
    ref.read(playerOverlayStackProvider.notifier).clear();
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
