import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

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
/// Updated by [_AppShellState] when the overlay opens / closes.
class QuickSearchOverlayVisibleNotifier extends Notifier<bool> {
  @override
  bool build() => false;

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
  const SearchResultsState({
    required this.result,
    required this.isWaitingForApi,
    required this.isLocalOnly,
  });

  final SearchResult3 result;
  final bool isWaitingForApi;
  final bool isLocalOnly;
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
      _rankByRelevance(
        await _searchLocal(ref, query, filter),
        query,
      ),
      filter,
    );

    if (isOffline) {
      yield SearchResultsState(
        result: localResult,
        isWaitingForApi: false,
        isLocalOnly: true,
      );
      return;
    }

    final api = ref.watch(subsonicApiProvider);
    if (api == null) {
      yield SearchResultsState(
        result: localResult,
        isWaitingForApi: false,
        isLocalOnly: true,
      );
      return;
    }

    final cancelToken = CancelToken();
    ref.onDispose(cancelToken.cancel);

    const defaultCount = 20;
    yield SearchResultsState(
      result: localResult,
      isWaitingForApi: true,
      isLocalOnly: false,
    );

    try {
      final apiResult = _filterResultByType(
        _rankByRelevance(
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
          _mergeCacheFirst(localResult, apiResult),
          filter,
        ),
        isWaitingForApi: false,
        isLocalOnly: false,
      );
    } on Object {
      yield SearchResultsState(
        result: localResult,
        isWaitingForApi: false,
        isLocalOnly: false,
      );
    }
  },
);

SearchResult3 _mergeCacheFirst(SearchResult3 local, SearchResult3 remote) {
  List<T> merge<T>(
    List<T> localItems,
    List<T> remoteItems,
    String Function(T) id,
  ) {
    final seen = localItems.map(id).toSet();
    return <T>[
      ...localItems,
      ...remoteItems.where((item) => seen.add(id(item))),
    ];
  }

  return SearchResult3(
    artists: merge(local.artists, remote.artists, (artist) => artist.id),
    albums: merge(local.albums, remote.albums, (album) => album.id),
    songs: merge(local.songs, remote.songs, (song) => song.id),
  );
}

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
            genre: a.genre,
            coverArt: a.coverArt,
            starred: a.starred,
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
          ),
        )
        .toList(),
  );
}

@immutable
class SearchExpandedParams {
  const SearchExpandedParams({
    required this.query,
    required this.type,
    this.offset = 0,
  });

  final String query;
  final SearchResultType type;
  final int offset;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearchExpandedParams &&
          query == other.query &&
          type == other.type &&
          offset == other.offset;

  @override
  int get hashCode => Object.hash(query, type, offset);
}

enum SearchResultType { artists, albums, songs }

final expandedSearchProvider = FutureProvider.autoDispose
    .family<SearchResult3, SearchExpandedParams>((ref, params) async {
      // In offline mode, use a larger local search limit for the expanded type.
      final isOffline = ref.watch(searchIsOfflineProvider);
      if (isOffline) {
        final dao = ref.read(navisDatabaseProvider).libraryDao;
        const expandedLimit = 100;

        switch (params.type) {
          case SearchResultType.artists:
            final results = await dao.searchArtistsLocal(
              params.query,
              limit: expandedLimit,
            );
            return _rankByRelevance(
              SearchResult3(
                artists: results
                    .map(
                      (a) =>
                          Artist(id: a.id, name: a.name, coverArt: a.coverArt),
                    )
                    .toList(),
              ),
              params.query,
            );
          case SearchResultType.albums:
            final results = await dao.searchAlbumsLocal(
              params.query,
              limit: expandedLimit,
            );
            return _rankByRelevance(
              SearchResult3(
                albums: results
                    .map(
                      (a) => Album(
                        id: a.id,
                        name: a.name,
                        artist: a.artistName,
                        coverArt: a.coverArt,
                      ),
                    )
                    .toList(),
              ),
              params.query,
            );
          case SearchResultType.songs:
            final results = await dao.searchSongsLocal(
              params.query,
              limit: expandedLimit,
            );
            return _rankByRelevance(
              SearchResult3(
                songs: results
                    .map(
                      (s) => Song(
                        id: s.id,
                        title: s.title,
                        artist: s.artistName,
                        album: s.albumName,
                        albumId: s.albumId,
                        duration: s.duration,
                        coverArt: s.coverArt,
                      ),
                    )
                    .toList(),
              ),
              params.query,
            );
        }
      }

      final api = ref.watch(subsonicApiProvider);
      if (api == null) {
        return const SearchResult3();
      }

      final cancelToken = CancelToken();
      ref.onDispose(cancelToken.cancel);

      const pageSize = 20;

      return _filterResultByType(
        _rankByRelevance(
          await api.search3(
            query: params.query,
            artistCount: params.type == SearchResultType.artists ? pageSize : 0,
            albumCount: params.type == SearchResultType.albums ? pageSize : 0,
            songCount: params.type == SearchResultType.songs ? pageSize : 0,
            artistOffset: params.type == SearchResultType.artists
                ? params.offset
                : 0,
            albumOffset: params.type == SearchResultType.albums
                ? params.offset
                : 0,
            songOffset: params.type == SearchResultType.songs
                ? params.offset
                : 0,
            cancelToken: cancelToken,
          ),
          params.query,
        ),
        params.type,
      );
    });

// ---------------------------------------------------------------------------
// Relevance ranking helpers
// ---------------------------------------------------------------------------

/// Scores [field] against [query] (both already lowercased at call site).
/// Lower score = better match.
///
/// 0 – exact match
/// 1 – field starts with query
/// 2 – field contains the full query as a substring
/// 3 – field contains every individual query word (handles "troopers" ⊃ "trooper")
/// 4 – no direct match
int _relevanceScore(String field, String query) {
  final f = field.toLowerCase();
  final q = query.toLowerCase();
  if (f == q) return 0;
  if (f.startsWith(q)) return 1;
  if (f.contains(q)) return 2;
  final words = q.split(RegExp(r'\s+'));
  if (words.length > 1 && words.every(f.contains)) return 3;
  return 4;
}

/// Stably re-sorts each list in [result] so the items whose primary field
/// best matches [query] come first.  Items with equal scores preserve their
/// original (server-returned) order.
SearchResult3 _rankByRelevance(SearchResult3 result, String query) {
  if (query.isEmpty) return result;

  List<T> rank<T>(List<T> items, String Function(T) field) {
    final indexed = List<(int, T)>.generate(items.length, (i) => (i, items[i]));
    indexed.sort((a, b) {
      final diff = _relevanceScore(
        field(a.$2),
        query,
      ).compareTo(_relevanceScore(field(b.$2), query));
      return diff != 0 ? diff : a.$1.compareTo(b.$1);
    });
    return indexed.map((e) => e.$2).toList(growable: false);
  }

  return SearchResult3(
    artists: rank(result.artists, (a) => a.name),
    albums: rank(result.albums, (a) => a.name),
    songs: rank(result.songs, (s) => s.title),
  );
}
