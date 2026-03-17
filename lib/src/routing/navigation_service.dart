import 'dart:async';

import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';

/// Tracks the last back-press timestamp for double-back-to-exit.
DateTime? _lastBackPress;

/// Centralised navigation helpers that guarantee a consistent UX:
///
/// * Collapsing the player sheet before cross-screen navigation.
/// * Using `context.go` for branch-aware transitions so the bottom-nav
///   indicator and back-stack stay correct.
/// * Dismissing shell-managed player overlays in strict top-first order.
abstract final class NavService {
  // ---------------------------------------------------------------------------
  // Library
  // ---------------------------------------------------------------------------

  /// Navigate to an album detail screen inside the Library branch.
  ///
  /// If the player sheet is expanded it is collapsed first so the destination
  /// is fully visible.  Any open modal (queue panel, overflow menu) is
  /// dismissed before navigating.
  static void goToAlbum(BuildContext context, WidgetRef ref, String albumId) {
    clearExitPrompt();
    _dismissOverlaysAndCollapse(context, ref);
    context.go('/library/albums/$albumId');
  }

  /// Navigate to an artist detail screen inside the Library branch.
  static void goToArtist(
    BuildContext context,
    WidgetRef ref,
    String artistId,
  ) {
    clearExitPrompt();
    _dismissOverlaysAndCollapse(context, ref);
    context.go('/library/artists/$artistId');
  }

  /// Navigate to the search screen and pre-fill the query.
  ///
  /// Useful for radio "search for this artist / song" flows.
  static void goToSearch(
    BuildContext context,
    WidgetRef ref,
    String query,
  ) {
    clearExitPrompt();
    _dismissOverlaysAndCollapse(context, ref);
    ref.read(searchQueryProvider.notifier).submit(query);
    context.go('/search');
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
      SystemNavigator.pop();
    } else {
      _lastBackPress = now;
      AppNoticeMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Press back again to exit'),
            duration: Duration(seconds: 2),
          ),
        );
    }
  }

  /// Clears any pending double-back-to-exit window after real navigation.
  static void clearExitPrompt() {
    _lastBackPress = null;
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  /// Dismiss any modal routes on the root navigator, then clear the shell's
  /// own player overlay stack.
  ///
  /// Called before [goToAlbum], [goToArtist], [goToSearch] to guarantee a
  /// clean navigation state.
  static void _dismissOverlaysAndCollapse(BuildContext context, WidgetRef ref) {
    dismissKeyboard(context);

    // Pop all modal routes above the shell route so GoRouter navigation
    // doesn't leave orphan overlays on the navigator.
    final rootNav = Navigator.of(context, rootNavigator: true);
    rootNav.popUntil((route) => route.isFirst);

    // Reset shell-managed player overlays so navigation starts clean.
    ref.read(playerOverlayStackProvider.notifier).clear();
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
