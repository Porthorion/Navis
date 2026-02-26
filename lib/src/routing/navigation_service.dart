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
  /// is fully visible.
  static void goToAlbum(BuildContext context, WidgetRef ref, String albumId) {
    _collapsePlayerIfNeeded(ref);
    context.go('/library/albums/$albumId');
  }

  /// Navigate to an artist detail screen inside the Library branch.
  static void goToArtist(
    BuildContext context,
    WidgetRef ref,
    String artistId,
  ) {
    _collapsePlayerIfNeeded(ref);
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
    _collapsePlayerIfNeeded(ref);
    ref.read(searchQueryProvider.notifier).submit(query);
    context.go('/search');
  }

  // ---------------------------------------------------------------------------
  // Player helpers
  // ---------------------------------------------------------------------------

  /// Show the playback queue as a full-screen modal bottom sheet.
  ///
  /// The sheet overlays the Now Playing view and can be dismissed by swiping
  /// down or tapping the close button.
  static void showQueue(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
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
  /// 1. **Player expanded** → collapse it.
  /// 2. **GoRouter can pop** (sub-route within a branch) → pop it.
  /// 3. **Not on Home tab** → switch to Home.
  /// 4. **Home tab root** → exit the app.
  static void handleSystemBack({
    required WidgetRef ref,
    required BuildContext context,
    required bool isPlayerExpanded,
    required StatefulNavigationShell navigationShell,
    required int homeBranchIndex,
  }) {
    // 1. Collapse the player if expanded
    if (isPlayerExpanded) {
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

  static void _collapsePlayerIfNeeded(WidgetRef ref) {
    final notifier = ref.read(playerSheetExpandedProvider.notifier);
    if (ref.read(playerSheetExpandedProvider)) {
      notifier.collapse();
    }
  }
}
