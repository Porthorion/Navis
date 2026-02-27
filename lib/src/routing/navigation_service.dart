import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/queue_sheet.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';

/// Tracks the last back-press timestamp for double-back-to-exit.
DateTime? _lastBackPress;

/// Centralised navigation helpers that guarantee a consistent UX:
///
/// * Collapsing the player sheet before cross-screen navigation.
/// * Using `context.go` for branch-aware transitions so the bottom-nav
///   indicator and back-stack stay correct.
/// * Showing the queue as a full-screen modal that keeps the player alive.
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
    _dismissOverlaysAndCollapse(context, ref);
    context.go('/library/albums/$albumId');
  }

  /// Navigate to an artist detail screen inside the Library branch.
  static void goToArtist(
    BuildContext context,
    WidgetRef ref,
    String artistId,
  ) {
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
    _dismissOverlaysAndCollapse(context, ref);
    ref.read(searchQueryProvider.notifier).submit(query);
    context.go('/search');
  }

  // ---------------------------------------------------------------------------
  // Player helpers
  // ---------------------------------------------------------------------------

  /// Show the playback queue as a full-screen modal bottom sheet.
  ///
  /// Uses the root navigator so the modal sits above everything (including
  /// the expanded player) and is properly handled by the back-button logic.
  static void showQueue(BuildContext context) {
    dismissKeyboard(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      requestFocus: false,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const QueueSheet(),
    );
  }

  // ---------------------------------------------------------------------------
  // Smart back-button behaviour
  // ---------------------------------------------------------------------------

  /// Handles system back (Android back gesture / button) with the following
  /// priority chain:
  ///
  /// **Important:** Modal routes (queue panel, dialogs, overflow menus) are
  /// popped by the Navigator *before* this method is called, because
  /// `PopScope(canPop: false)` only triggers `onPopInvokedWithResult` when
  /// the shell route is the topmost route.
  ///
  /// 1. **Player expanded** → collapse it.
  /// 2. **GoRouter can pop** (sub-route within a branch) → pop it.
  /// 3. **Not on Home tab** → switch to Home.
  /// 4. **Home tab root** → require double-tap to exit.
  static void handleSystemBack({
    required WidgetRef ref,
    required BuildContext context,
    required bool isPlayerExpanded,
    required StatefulNavigationShell navigationShell,
    required int homeBranchIndex,
  }) {
    // 1. Collapse the player if expanded
    if (isPlayerExpanded) {
      dismissKeyboard(context);
      ref.read(playerSheetExpandedProvider.notifier).collapse();
      return;
    }

    // 2. Pop sub-route (e.g. album detail → library root)
    if (GoRouter.of(context).canPop()) {
      context.pop();
      return;
    }

    // 3. Go home if we're on another tab's root
    if (navigationShell.currentIndex != homeBranchIndex) {
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
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Press back again to exit'),
            duration: Duration(seconds: 2),
          ),
        );
    }
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  /// Dismiss any modal routes (queue panel, overflow menus, dialogs) that
  /// are on the root navigator, then collapse the player sheet.
  ///
  /// Called before [goToAlbum], [goToArtist], [goToSearch] to guarantee a
  /// clean navigation state.
  static void _dismissOverlaysAndCollapse(BuildContext context, WidgetRef ref) {
    dismissKeyboard(context);

    // Pop all modal routes above the shell route so GoRouter navigation
    // doesn't leave orphan overlays on the navigator.
    final rootNav = Navigator.of(context, rootNavigator: true);
    rootNav.popUntil((route) => route.isFirst);

    // Collapse the expanded player.
    final notifier = ref.read(playerSheetExpandedProvider.notifier);
    if (ref.read(playerSheetExpandedProvider)) {
      notifier.collapse();
    }
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
