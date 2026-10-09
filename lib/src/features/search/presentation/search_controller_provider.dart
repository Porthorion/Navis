/// @docImport 'package:navis/src/routing/app_shell.dart';
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/search/domain/search_result_ranker.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/sync_diagnostics_overrides.dart';

class SearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  // ignore: use_setters_to_change_properties // `submit` is a user-intent action verb, not a property setter
  void submit(String value) => state = value;

  void clear() => state = '';
}

final searchQueryProvider = NotifierProvider<SearchQueryNotifier, String>(
  SearchQueryNotifier.new,
);

/// A simple counter that increments every time the search tab is tapped.
/// The search screen watches this to re-request focus.
class SearchFocusRequestNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void increment() => state++;
}

final searchFocusRequestProvider =
    NotifierProvider<SearchFocusRequestNotifier, int>(
      SearchFocusRequestNotifier.new,
    );

final recentSearchesProvider = StreamProvider<List<RecentSearchesTableData>>((
  ref,
) {
  final dao = ref.watch(navisDatabaseProvider).historyDao;
  return dao.watchRecentSearches(limit: 20);
});

/// Selected search type filter. `null` means "All".
class SearchFilterNotifier extends Notifier<SearchResultType?> {
  @override
  SearchResultType? build() => null;

  // ignore: use_setters_to_change_properties — `select` is a user-intent action verb, not a property setter
  void select(SearchResultType? type) => state = type;
}

final searchFilterProvider =
    NotifierProvider<SearchFilterNotifier, SearchResultType?>(
      SearchFilterNotifier.new,
    );

/// Whether the desktop quick-search overlay is currently visible.
/// Updated by [AppShell] when the overlay opens / closes.
class QuickSearchOverlayVisibleNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  bool get visible => state;

  set visible(bool value) => state = value;
}

final quickSearchOverlayVisibleProvider =
    NotifierProvider<QuickSearchOverlayVisibleNotifier, bool>(
      QuickSearchOverlayVisibleNotifier.new,
    );

/// Whether the current search is running against the local DB (offline).
final searchIsOfflineProvider = Provider.autoDispose<bool>((ref) {
  final reachability = ref.watch(serverReachabilityControllerProvider);
  return reachability.status != ServerReachabilityStatus.online;
});

@immutable
class SearchResultsState {
  const new({
    required this.result,
    required this.isWaitingForApi,
    required this.isLocalOnly,
    required this.remoteSearchFailed,
  });

  final SearchResult3 result;
  final bool isWaitingForApi;
  final bool isLocalOnly;

  /// True when local search completed but the online supplement failed.
  /// Callers should preserve useful local results and offer recovery when the
  /// result would otherwise look like an authoritative empty search.
  final bool remoteSearchFailed;
}

final debouncedSearchProvider = StreamProvider.autoDispose<SearchResultsState?>(
  (ref) async* {
    final query = ref.watch(searchQueryProvider).trim();
    if (query.isEmpty) {
      yield null;
      return;
    }

    final completer = Completer<void>();
    final timer = Timer(const Duration(milliseconds: 300), completer.complete);
    ref.onDispose(timer.cancel);
    await completer.future;

    final filter = ref.watch(searchFilterProvider);
    final isOffline = ref.watch(searchIsOfflineProvider);
    final localResult = _filterResultByType(
      rankSearchResult(await _searchLocal(ref, query, filter), query),
      filter,
    );

    if (isOffline) {
      yield SearchResultsState(
        result: localResult,
        isWaitingForApi: false,
        isLocalOnly: true,
        remoteSearchFailed: false,
      );
      return;
    }

    final api = ref.watch(subsonicApiProvider);
    if (api == null) {
      yield SearchResultsState(
        result: localResult,
        isWaitingForApi: false,
        isLocalOnly: true,
        remoteSearchFailed: false,
      );
      return;
    }

    final cancelToken = CancelToken();
    ref.onDispose(cancelToken.cancel);
    final forceRemoteFailure = ref.watch(
      syncDiagnosticsOverridesProvider.select(
        (overrides) => overrides.forceSearchRemoteFailure,
      ),
    );

    const defaultCount = 20;
    yield SearchResultsState(
      result: localResult,
      isWaitingForApi: true,
      isLocalOnly: false,
      remoteSearchFailed: false,
    );

    try {
      if (forceRemoteFailure) {
        throw StateError('Remote search failure injected by diagnostics.');
      }
      final apiResult = _filterResultByType(
        rankSearchResult(
          await api.search3(
            query: query,
            artistCount: filter == null || filter == SearchResultType.artists
                ? defaultCount
                : 0,
            albumCount: filter == null || filter == SearchResultType.albums
                ? defaultCount
                : 0,
            songCount: filter == null || filter == SearchResultType.songs
                ? defaultCount
                : 0,
            cancelToken: cancelToken,
          ),
          query,
        ),
        filter,
      );
      yield SearchResultsState(
        result: _filterResultByType(
          mergeAndRankSearchResults(
            local: localResult,
            api: apiResult,
            query: query,
          ),
          filter,
        ),
        isWaitingForApi: false,
        isLocalOnly: false,
        remoteSearchFailed: false,
      );
    } on Object {
      yield SearchResultsState(
        result: localResult,
        isWaitingForApi: false,
        isLocalOnly: false,
        remoteSearchFailed: true,
      );
    }
  },
);

SearchResult3 _filterResultByType(
  SearchResult3 result,
  SearchResultType? filter,
) {
  switch (filter) {
    case null:
      return result;
    case SearchResultType.artists:
      return SearchResult3(artists: result.artists);
    case SearchResultType.albums:
      return SearchResult3(albums: result.albums);
    case SearchResultType.songs:
      return SearchResult3(songs: result.songs);
  }
}

/// Perform a local (offline) search using Drift LIKE queries.
Future<SearchResult3> _searchLocal(
  Ref ref,
  String query,
  SearchResultType? filter,
) async {
  final dao = ref.read(navisDatabaseProvider).libraryDao;

  final artistRows = filter == null || filter == SearchResultType.artists
      ? await dao.searchArtistsLocal(query)
      : <ArtistsTableData>[];

  final albumRows = filter == null || filter == SearchResultType.albums
      ? await dao.searchAlbumsLocal(query)
      : <AlbumsTableData>[];

  final songRows = filter == null || filter == SearchResultType.songs
      ? await dao.searchSongsLocal(query)
      : <SongsTableData>[];

  return SearchResult3(
    artists: artistRows
        .map(
          (a) => Artist(
            id: a.id,
            name: a.name,
            coverArt: a.coverArt,
            starred: a.starred,
            isExternal: a.isExternal,
          ),
        )
        .toList(),
    albums: albumRows
        .map(
          (a) => Album(
            id: a.id,
            name: a.name,
            artist: a.artistName,
            artistId: a.artistId,
            songCount: a.songCount,
            year: a.year,
            coverArt: a.coverArt,
            starred: a.starred,
            isExternal: a.isExternal,
          ),
        )
        .toList(),
    songs: songRows
        .map(
          (s) => Song(
            id: s.id,
            title: s.title,
            album: s.albumName,
            albumId: s.albumId,
            artist: s.artistName,
            artistId: s.artistId,
            track: s.track,
            duration: s.duration,
            coverArt: s.coverArt,
            starred: s.starred,
            isExternal: s.isExternal,
          ),
        )
        .toList(),
  );
}

enum SearchResultType { artists, albums, songs }
