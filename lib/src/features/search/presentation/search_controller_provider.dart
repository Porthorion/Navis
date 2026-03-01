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

/// Whether the current search is running against the local DB (offline).
final searchIsOfflineProvider = Provider.autoDispose<bool>((ref) {
  final reachability = ref.watch(serverReachabilityControllerProvider);
  return reachability.status != ServerReachabilityStatus.online;
});

final debouncedSearchProvider = FutureProvider.autoDispose<SearchResult3?>((
  ref,
) async {
  final query = ref.watch(searchQueryProvider).trim();
  if (query.isEmpty) {
    return null;
  }

  final completer = Completer<void>();
  final timer = Timer(const Duration(milliseconds: 300), completer.complete);
  ref.onDispose(timer.cancel);
  await completer.future;

  final filter = ref.watch(searchFilterProvider);
  final isOffline = ref.watch(searchIsOfflineProvider);

  if (isOffline) {
    return _searchLocal(ref, query, filter);
  }

  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return _searchLocal(ref, query, filter);
  }

  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);

  const defaultCount = 20;

  try {
    return await api.search3(
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
    );
  } on Object {
    // Fall back to local search on any network error.
    return _searchLocal(ref, query, filter);
  }
});

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
            return SearchResult3(
              artists: results
                  .map(
                    (a) => Artist(id: a.id, name: a.name, coverArt: a.coverArt),
                  )
                  .toList(),
            );
          case SearchResultType.albums:
            final results = await dao.searchAlbumsLocal(
              params.query,
              limit: expandedLimit,
            );
            return SearchResult3(
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
            );
          case SearchResultType.songs:
            final results = await dao.searchSongsLocal(
              params.query,
              limit: expandedLimit,
            );
            return SearchResult3(
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

      return api.search3(
        query: params.query,
        artistCount: params.type == SearchResultType.artists ? pageSize : 0,
        albumCount: params.type == SearchResultType.albums ? pageSize : 0,
        songCount: params.type == SearchResultType.songs ? pageSize : 0,
        artistOffset: params.type == SearchResultType.artists
            ? params.offset
            : 0,
        albumOffset: params.type == SearchResultType.albums ? params.offset : 0,
        songOffset: params.type == SearchResultType.songs ? params.offset : 0,
        cancelToken: cancelToken,
      );
    });
