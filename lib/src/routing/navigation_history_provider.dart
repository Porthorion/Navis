import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/routing/app_router.dart';
import 'package:navis/src/routing/navigation_history.dart';

/// Immutable desktop navigation history: visited [entries] and the current
/// [index] within them.
@immutable
class NavigationHistoryState {
  const NavigationHistoryState({
    this.entries = const <NavHistoryEntry>[],
    this.index = -1,
  });

  final List<NavHistoryEntry> entries;
  final int index;

  bool get canGoBack => index > 0;
  bool get canGoForward => index >= 0 && index < entries.length - 1;

  /// Visible locations, oldest first.
  List<String> get stack => <String>[
    for (final entry in entries) entry.uri.toString(),
  ];
}

/// Desktop back/forward history across tabs.
///
/// Records every change of the router's configuration while a shell location
/// is shown. Going back to the page directly beneath the current one pops it;
/// every other move restores the recorded [RouteMatchList], so tabs keep
/// their page stacks, pages keep their state, and `extra` payloads survive.
class NavigationHistoryNotifier extends Notifier<NavigationHistoryState> {
  /// Maximum number of remembered entries.
  static const capacity = 100;

  GoRouter? _router;

  /// The entry a back/forward move is heading to, until the router confirms
  /// it. A different result (for example a redirect) is recorded as new
  /// navigation instead.
  int? _pendingIndex;

  @override
  NavigationHistoryState build() {
    final router = ref.watch(appRouterProvider);
    _router = router;
    _pendingIndex = null;

    void onRouteChanged() =>
        _record(router.routerDelegate.currentConfiguration);

    router.routerDelegate.addListener(onRouteChanged);
    ref.onDispose(() => router.routerDelegate.removeListener(onRouteChanged));
    ref.listen<SessionRoutePhase>(sessionRoutePhaseProvider, (_, next) {
      if (next == SessionRoutePhase.unauthenticated) {
        _pendingIndex = null;
        state = const NavigationHistoryState();
      }
    });

    final initial = NavHistoryEntry.fromConfiguration(
      router.routerDelegate.currentConfiguration,
    );
    return initial == null
        ? const NavigationHistoryState()
        : NavigationHistoryState(
            entries: <NavHistoryEntry>[initial],
            index: 0,
          );
  }

  void _record(RouteMatchList configuration) {
    final entry = NavHistoryEntry.fromConfiguration(configuration);
    if (entry == null) {
      return;
    }
    final entries = state.entries;
    final pending = _pendingIndex;
    _pendingIndex = null;
    if (pending != null &&
        pending < entries.length &&
        entries[pending].sameLocation(entry)) {
      _replaceAt(pending, entry, index: pending);
      return;
    }
    final index = state.index;
    if (index >= 0 && entries[index].sameLocation(entry)) {
      // The same location re-emitted, e.g. with new route extras.
      _replaceAt(index, entry, index: index);
      return;
    }
    if (index > 0 &&
        entries[index - 1].sameLocation(entry) &&
        entry.isPopOf(entries[index])) {
      // A page back button or system back popped the current page.
      _replaceAt(index - 1, entry, index: index - 1);
      return;
    }
    // New navigation discards forward history, like a browser.
    var next = <NavHistoryEntry>[...entries.sublist(0, index + 1), entry];
    if (next.length > capacity) {
      next = next.sublist(next.length - capacity);
    }
    state = NavigationHistoryState(
      entries: List<NavHistoryEntry>.unmodifiable(next),
      index: next.length - 1,
    );
  }

  void _replaceAt(int position, NavHistoryEntry entry, {required int index}) {
    final next = List<NavHistoryEntry>.of(state.entries)..[position] = entry;
    state = NavigationHistoryState(
      entries: List<NavHistoryEntry>.unmodifiable(next),
      index: index,
    );
  }

  /// Go to the previous history entry (mouse Back, Alt+Left, header button).
  void navigateBack() {
    if (!state.canGoBack) {
      return;
    }
    _moveTo(state.index - 1);
  }

  /// Go to the next history entry (mouse Forward, Alt+Right, header button).
  void navigateForward() {
    if (!state.canGoForward) {
      return;
    }
    _moveTo(state.index + 1);
  }

  void _moveTo(int targetIndex) {
    final router = _router;
    if (router == null) {
      return;
    }
    final current = state.entries[state.index];
    final target = state.entries[targetIndex];
    _prepareForHistoryNavigation(router);
    _pendingIndex = targetIndex;
    state = NavigationHistoryState(entries: state.entries, index: targetIndex);
    if (target.isPopOf(current) && router.canPop()) {
      // Popping completes the page's push future, which pages such as the
      // Equalizer use to restore where they were opened from.
      router.pop();
      return;
    }
    router.restore(rehydrateNavigationSnapshot(target.snapshot));
  }

  /// Clears transient surfaces before history moves, like NavService does
  /// for other navigation: the keyboard, popup routes and player overlays.
  void _prepareForHistoryNavigation(GoRouter router) {
    FocusManager.instance.primaryFocus?.unfocus();
    router.routerDelegate.navigatorKey.currentState?.popUntil(
      (route) => route is! PopupRoute,
    );
    ref.read(playerOverlayStackProvider.notifier).clear();
  }
}

final navigationHistoryProvider =
    NotifierProvider<NavigationHistoryNotifier, NavigationHistoryState>(
      NavigationHistoryNotifier.new,
    );
