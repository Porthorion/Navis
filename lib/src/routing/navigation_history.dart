import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

/// One visited location in desktop navigation history.
///
/// It keeps the router's whole [RouteMatchList] rather than a URI, so going
/// back or forward restores the exact page stack of its tab, including
/// pushed pages, their page keys and their `extra` payloads, instead of
/// rebuilding a stack from a URL.
@immutable
class NavHistoryEntry {
  const NavHistoryEntry._({
    required this.snapshot,
    required this.branch,
    required this.pageKeys,
  });

  /// Describes [configuration], or returns null when it is not a shell
  /// location (sign-in, onboarding, full-screen rebuilds), which history
  /// never records.
  static NavHistoryEntry? fromConfiguration(RouteMatchList configuration) {
    if (configuration.isEmpty || configuration.isError) {
      return null;
    }
    final shellMatch = _statefulShellMatch(configuration.matches);
    if (shellMatch == null) {
      return null;
    }
    final shellRoute = shellMatch.route as StatefulShellRoute;
    final branch = shellRoute.branches.indexWhere(
      (branch) => branch.navigatorKey == shellMatch.navigatorKey,
    );
    if (branch < 0) {
      return null;
    }
    return NavHistoryEntry._(
      snapshot: configuration,
      branch: branch,
      pageKeys: List<String>.unmodifiable(_pageKeys(configuration.matches)),
    );
  }

  /// The router configuration to restore.
  final RouteMatchList snapshot;

  /// The shell branch (tab) index.
  final int branch;

  /// Page keys of the tab's stack, bottom to top.
  final List<String> pageKeys;

  /// The visible location, including pushed pages and query parameters.
  Uri get uri => _topUri(snapshot);

  /// Whether [other] shows the same pages at the same location.
  bool sameLocation(NavHistoryEntry other) =>
      branch == other.branch &&
      listEquals(pageKeys, other.pageKeys) &&
      uri == other.uri;

  /// Whether this entry is [above] with its top page popped.
  bool isPopOf(NavHistoryEntry above) =>
      branch == above.branch &&
      pageKeys.length + 1 == above.pageKeys.length &&
      listEquals(pageKeys, above.pageKeys.sublist(0, pageKeys.length));

  static ShellRouteMatch? _statefulShellMatch(List<RouteMatchBase> matches) {
    for (final match in matches) {
      if (match is ShellRouteMatch) {
        if (match.route is StatefulShellRoute) {
          return match;
        }
        final nested = _statefulShellMatch(match.matches);
        if (nested != null) {
          return nested;
        }
      }
    }
    return null;
  }

  static Iterable<String> _pageKeys(List<RouteMatchBase> matches) sync* {
    for (final match in matches) {
      if (match is ShellRouteMatch) {
        yield* _pageKeys(match.matches);
      } else {
        yield match.pageKey.value;
      }
    }
  }

  static Uri _topUri(RouteMatchList configuration) {
    RouteMatchBase? top = configuration.matches.lastOrNull;
    while (top is ShellRouteMatch) {
      top = top.matches.lastOrNull;
    }
    if (top is ImperativeRouteMatch) {
      return top.matches.uri;
    }
    return configuration.uri;
  }
}

/// Returns [configuration] with every already-completed pushed page given a
/// fresh completer.
///
/// A pushed page's completer completes when it is popped. Restoring a
/// snapshot that still contains that page and popping it again would
/// complete the same completer twice, so restored pages get new ones.
RouteMatchList rehydrateNavigationSnapshot(RouteMatchList configuration) {
  List<RouteMatchBase> rehydrate(List<RouteMatchBase> matches) {
    return <RouteMatchBase>[
      for (final match in matches)
        switch (match) {
          final ShellRouteMatch shell => ShellRouteMatch(
            route: shell.route,
            matches: rehydrate(shell.matches),
            matchedLocation: shell.matchedLocation,
            pageKey: shell.pageKey,
            navigatorKey: shell.navigatorKey,
          ),
          final ImperativeRouteMatch pushed when pushed.completer.isCompleted =>
            ImperativeRouteMatch(
              pageKey: pushed.pageKey,
              matches: pushed.matches,
              completer: Completer<Object?>(),
            ),
          _ => match,
        },
    ];
  }

  return RouteMatchList(
    matches: rehydrate(configuration.matches),
    uri: configuration.uri,
    extra: configuration.extra,
    error: configuration.error,
    pathParameters: configuration.pathParameters,
  );
}
