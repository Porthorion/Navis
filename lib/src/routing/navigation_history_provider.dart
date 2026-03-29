import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app_router.dart';
import '../features/library/presentation/library_scroll_provider.dart';

/// Immutable snapshot of the navigation history.
///
/// [stack] is the ordered list of URI strings visited, [index] is the
/// current position within that list.
///
/// Library section tabs are encoded as virtual destinations using a URI
/// fragment, e.g. `/library#artists`, so that switching between Albums,
/// Artists, Playlists, Liked, and Radio is fully captured in history.
class NavigationHistoryState {
  const NavigationHistoryState({
    this.stack = const [],
    this.index = -1,
  });

  final List<String> stack;
  final int index;

  bool get canGoBack => index > 0;
  bool get canGoForward => index < stack.length - 1;

  String? get previousLocation => canGoBack ? stack[index - 1] : null;
  String? get nextLocation => canGoForward ? stack[index + 1] : null;
}

/// Notifier that tracks navigation history and powers mouse back/forward
/// button support on desktop.
///
/// GoRouter-level routes are captured via the [GoRouterDelegate] change
/// listener. Library section tab changes are captured via a separate
/// [librarySectionProvider] listener and stored as `/library#sectionName`.
class NavigationHistoryNotifier extends Notifier<NavigationHistoryState> {
  // Suppress recording while we are performing our own history navigation so
  // we don't double-add an entry.
  bool _suppressRecord = false;

  @override
  NavigationHistoryState build() {
    final router = ref.watch(appRouterProvider);

    // --- GoRouter route changes ---
    void onRouteChanged() {
      if (_suppressRecord) return;
      final uri = router.state.uri.toString();
      // When landing on the library root, encode the active section so the
      // history entry is fully specific (e.g. back from album detail).
      if (uri == '/library') {
        final section = ref.read(librarySectionProvider);
        _record('/library#${section.name}');
      } else {
        _record(uri);
      }
    }

    router.routerDelegate.addListener(onRouteChanged);
    ref.onDispose(() => router.routerDelegate.removeListener(onRouteChanged));

    // --- Library section tab changes ---
    // Only record when the GoRouter is actually on the library root screen.
    // Navigating to a detail route (e.g. /library/albums/123) does not change
    // the section, so this listener stays quiet during detail navigation.
    ref.listen(librarySectionProvider, (prev, next) {
      if (_suppressRecord) return;
      final uri = router.state.uri.toString();
      if (uri == '/library') {
        _record('/library#${next.name}');
      }
    });

    return const NavigationHistoryState();
  }

  void _record(String location) {
    // Drop consecutive duplicates (e.g. same URL re-emitted on rebuild).
    if (state.index >= 0 &&
        state.stack.isNotEmpty &&
        state.stack[state.index] == location) {
      return;
    }
    // Everything after the current index is discarded on new navigation,
    // exactly like a browser.
    final newStack = [
      ...state.stack.sublist(0, state.index + 1),
      location,
    ];
    state = NavigationHistoryState(
      stack: newStack,
      index: newStack.length - 1,
    );
  }

  /// Navigate to the previous location in history (mouse back button).
  void navigateBack(GoRouter router) {
    final target = state.previousLocation;
    if (target == null) return;
    _suppressRecord = true;
    state = NavigationHistoryState(
      stack: state.stack,
      index: state.index - 1,
    );
    _applyLocation(router, target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _suppressRecord = false;
    });
  }

  /// Navigate to the next location in history (mouse forward button).
  void navigateForward(GoRouter router) {
    final target = state.nextLocation;
    if (target == null) return;
    _suppressRecord = true;
    state = NavigationHistoryState(
      stack: state.stack,
      index: state.index + 1,
    );
    _applyLocation(router, target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _suppressRecord = false;
    });
  }

  /// Apply [location] to the live UI.
  ///
  /// Virtual library-section entries (`/library#sectionName`) are decoded
  /// back into a router navigation + section provider update. All other
  /// entries are a plain [GoRouter.go] call.
  void _applyLocation(GoRouter router, String location) {
    if (location.startsWith('/library#')) {
      final sectionName = location.substring('/library#'.length);
      final section = LibrarySection.values.firstWhere(
        (s) => s.name == sectionName,
        orElse: () => LibrarySection.albums,
      );
      // Navigate to the library root if not already there.
      final currentUri = router.state.uri.toString();
      if (currentUri != '/library') {
        router.go('/library');
      }
      ref.read(librarySectionProvider.notifier).setSection(section);
    } else {
      router.go(location);
    }
  }
}

final navigationHistoryProvider =
    NotifierProvider<NavigationHistoryNotifier, NavigationHistoryState>(
      NavigationHistoryNotifier.new,
    );
