import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shell-managed player surfaces ordered from bottom to top.
enum PlayerOverlayRoute { nowPlaying, queue }

/// Controls the stack of player surfaces shown above the main shell content.
///
/// The shell treats player UI as its own overlay stack instead of a single
/// boolean so back handling can always dismiss the top-most player surface
/// before it touches branch navigation or app exit.
class PlayerOverlayController extends Notifier<List<PlayerOverlayRoute>> {
  @override
  List<PlayerOverlayRoute> build() => const <PlayerOverlayRoute>[];

  void expand() => _push(PlayerOverlayRoute.nowPlaying);

  void collapse() => _truncateFrom(PlayerOverlayRoute.nowPlaying);

  void showQueue() {
    expand();
    _push(PlayerOverlayRoute.queue);
  }

  /// Shows only the queue overlay without forcing the now-playing route.
  ///
  /// Desktop's in-place queue panel uses this so queue can be treated like a
  /// lightweight popover instead of a full now-playing transition.
  void showQueueOnly() => _push(PlayerOverlayRoute.queue);

  void hideQueue() => _truncateFrom(PlayerOverlayRoute.queue);

  bool dismissTop() {
    if (state.isEmpty) {
      return false;
    }
    state = List<PlayerOverlayRoute>.unmodifiable(
      state.sublist(0, state.length - 1),
    );
    return true;
  }

  void clear() => state = const <PlayerOverlayRoute>[];

  void toggle() {
    if (state.contains(PlayerOverlayRoute.nowPlaying)) {
      collapse();
    } else {
      expand();
    }
  }

  void _push(PlayerOverlayRoute route) {
    final next = List<PlayerOverlayRoute>.of(state)..remove(route);
    next.add(route);
    state = List<PlayerOverlayRoute>.unmodifiable(next);
  }

  void _truncateFrom(PlayerOverlayRoute route) {
    final index = state.indexOf(route);
    if (index == -1) {
      return;
    }
    state = List<PlayerOverlayRoute>.unmodifiable(state.sublist(0, index));
  }
}

final playerOverlayStackProvider =
    NotifierProvider<PlayerOverlayController, List<PlayerOverlayRoute>>(
      PlayerOverlayController.new,
    );

final playerSheetExpandedProvider = Provider<bool>((ref) {
  return ref.watch(
    playerOverlayStackProvider.select(
      (stack) => stack.contains(PlayerOverlayRoute.nowPlaying),
    ),
  );
});

final queueOverlayVisibleProvider = Provider<bool>((ref) {
  return ref.watch(
    playerOverlayStackProvider.select(
      (stack) => stack.contains(PlayerOverlayRoute.queue),
    ),
  );
});
