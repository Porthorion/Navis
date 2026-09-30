import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/routing/app_router.dart';
import 'package:navis/src/routing/app_routes.dart';

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
      _record(_currentLocation(router));
    }

    router.routerDelegate.addListener(onRouteChanged);
    ref.onDispose(() => router.routerDelegate.removeListener(onRouteChanged));

    // --- Library section tab changes ---
    // Only record when the GoRouter is actually on the library root screen.
    // Navigating to a detail route (e.g. /library/albums/123) does not change
    // the section, so this listener stays quiet during detail navigation.
    ref.listen(librarySectionProvider, (prev, next) {
      if (_suppressRecord) return;
      if (_isLibraryRoot(router.state.uri)) {
        _record('${AppRoutes.library}#${next.name}');
      }
    });

    return const NavigationHistoryState();
  }

  void _record(String location) {
    final normalized = _normalizeLocation(location);
    if (normalized == null) {
      return;
    }
    // Drop consecutive duplicates (e.g. same URL re-emitted on rebuild).
    if (state.index >= 0 &&
        state.stack.isNotEmpty &&
        state.stack[state.index] == normalized) {
      return;
    }
    // Everything after the current index is discarded on new navigation,
    // exactly like a browser.
    final newStack = [
      ...state.stack.sublist(0, state.index + 1),
      normalized,
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
    final normalized = _normalizeLocation(location);
    if (normalized == null) {
      return;
    }
    if (normalized.startsWith('${AppRoutes.library}#')) {
      final sectionName = normalized.substring('${AppRoutes.library}#'.length);
      final section = LibrarySection.values.firstWhere(
        (s) => s.name == sectionName,
        orElse: () => LibrarySection.albums,
      );
      // Navigate to the library root if not already there.
      if (!_isLibraryRoot(router.state.uri)) {
        router.go(AppRoutes.library);
      }
      ref.read(librarySectionProvider.notifier).setSection(section);
    } else {
      router.go(normalized);
    }
  }

  String _currentLocation(GoRouter router) {
    final uri = router.state.uri;
    if (_isLibraryRoot(uri)) {
      final section = uri.fragment.isNotEmpty
          ? _librarySectionFromName(uri.fragment)
          : ref.read(librarySectionProvider);
      return '${AppRoutes.library}#${section.name}';
    }
    return uri.toString();
  }

  String? _normalizeLocation(String location) {
    final uri = Uri.tryParse(location);
    if (uri == null) {
      return null;
    }
    if (_isLibraryRoot(uri)) {
      final section = uri.fragment.isNotEmpty
          ? _librarySectionFromName(uri.fragment)
          : ref.read(librarySectionProvider);
      return '${AppRoutes.library}#${section.name}';
    }
    if (uri.path == AppRoutes.library && uri.fragment.isNotEmpty) {
      final section = _librarySectionFromName(uri.fragment);
      return '${AppRoutes.library}#${section.name}';
    }
    return uri.toString();
  }

  bool _isLibraryRoot(Uri uri) {
    return uri.path == AppRoutes.library && uri.query.isEmpty;
  }

  LibrarySection _librarySectionFromName(String name) {
    return LibrarySection.values.firstWhere(
      (section) => section.name == name,
      orElse: () => LibrarySection.albums,
    );
  }
}

final navigationHistoryProvider =
    NotifierProvider<NavigationHistoryNotifier, NavigationHistoryState>(
      NavigationHistoryNotifier.new,
    );
