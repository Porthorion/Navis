/// @docImport 'package:navis/src/routing/app_shell.dart';
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/daos/library_dao.dart' show GenreSummary;
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/features/search/domain/deezer_search_boost.dart';
import 'package:navis/src/features/search/domain/search_result_ranker.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
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
  return reachability.status == ServerReachabilityStatus.offline;
});

@immutable
class SearchResultsState {
  const new({
    required this.result,
    required this.isWaitingForApi,
    required this.isLocalOnly,
    required this.remoteSearchFailed,
    this.genres = const <GenreSummary>[],
    this.topResults = const <SearchTopResult>[],
  });

  final SearchResult3 result;

  /// Up to [kMaxTopResults] items Deezer's popularity ranking matched to the
  /// results; empty without Deezer's answer in time.
  final List<SearchTopResult> topResults;

  /// Genres matching the query from the local index, so they work offline;
  /// empty while the Genres page is hidden or a type filter is active.
  final List<GenreSummary> genres;
  final bool isWaitingForApi;
  final bool isLocalOnly;

  /// True when local search completed but the online supplement failed.
  /// Callers should preserve useful local results and offer recovery when the
  /// result would otherwise look like an authoritative empty search.
  final bool remoteSearchFailed;
}

/// How long Search waits for Deezer past the server's answer. A later answer
/// is ignored: the results never reshuffle after they show.
const Duration kSearchDeezerWait = Duration(milliseconds: 350);

/// Span names on `IntegrationCallRecorder`, for the diagnostics endpoint:
/// Deezer's own time, and what Search made of it (how long it waited, and
/// whether the answer was in time).
const String kSearchDeezerSpan = 'search.deezer';
const String kSearchDeezerRankSpan = 'search.deezerRank';

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
    // Genre names live only in the local index and show under All only.
    final genres = filter == null && ref.watch(showGenresPageProvider)
        ? await ref
              .read(navisDatabaseProvider)
              .libraryDao
              .searchGenres(query, limit: 5)
        : const <GenreSummary>[];

    if (isOffline || filter?.isCollection == true) {
      // Playlists and radio are matched in memory by
      // [searchCollectionMatchesProvider]; nothing to ask the server.
      yield SearchResultsState(
        genres: genres,
        result: localResult,
        isWaitingForApi: false,
        isLocalOnly: isOffline,
        remoteSearchFailed: false,
      );
      return;
    }

    final api = ref.watch(subsonicApiProvider);
    if (api == null) {
      yield SearchResultsState(
        genres: genres,
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

    // Deezer starts with the server search and is waited for only briefly.
    final deezer = _startDeezerSearch(ref, query, filter, cancelToken);

    const defaultCount = 20;
    yield SearchResultsState(
      genres: genres,
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
      var merged = _filterResultByType(
        mergeAndRankSearchResults(
          local: localResult,
          api: apiResult,
          query: query,
        ),
        filter,
      );
      var topResults = const <SearchTopResult>[];
      if (deezer != null) {
        final waited = Stopwatch()..start();
        final hits = await deezer.timeout(
          kSearchDeezerWait,
          onTimeout: () => null,
        );
        // The query changed while waiting: this answer is dropped.
        if (!ref.mounted) return;
        var ranked = 0;
        if (hits != null) {
          try {
            final boost = matchDeezerSearchHits(result: merged, hits: hits);
            merged = rankSearchResult(
              merged,
              query,
              popularity: boost.popularity,
            );
            topResults = boost.topResults;
            ranked =
                boost.popularity.artists.length +
                boost.popularity.albums.length +
                boost.popularity.songs.length;
          } on Object catch (error) {
            // Ranking is an extra: keep today's order.
            AppLogger.debug('Search: Deezer ranking failed: $error');
          }
        }
        ref.read(integrationCallRecorderProvider).span(
          kSearchDeezerRankSpan,
          <String, int>{
            'inTime': hits == null ? 0 : 1,
            'ranked': ranked,
            'topResults': topResults.length,
          },
          waited.elapsed,
        );
      }
      yield SearchResultsState(
        genres: genres,
        result: merged,
        topResults: topResults,
        isWaitingForApi: false,
        isLocalOnly: false,
        remoteSearchFailed: false,
      );
    } on Object {
      yield SearchResultsState(
        genres: genres,
        result: localResult,
        isWaitingForApi: false,
        isLocalOnly: false,
        remoteSearchFailed: true,
      );
    }
  },
);

/// Starts Deezer's search for [query] when `deezer.searchRanking` allows it
/// (switch, service and master on), asking only the endpoint a type [filter]
/// shows. The future never throws: an endpoint that fails or is cancelled
/// reads as no hits, and the span records Deezer's own time. (Nullable only
/// so the caller's timeout can answer null.) Null when nothing may be sent.
Future<DeezerSearchHits?>? _startDeezerSearch(
  Ref ref,
  String query,
  SearchResultType? filter,
  CancelToken cancelToken,
) {
  if (!ref
      .read(integrationPolicyProvider)
      .allows(IntegrationFeature.deezerSearchRanking)) {
    return null;
  }
  final catalog = ref.read(deezerCatalogProvider);
  final recorder = ref.read(integrationCallRecorderProvider);
  final timer = Stopwatch()..start();
  var failed = 0;
  Future<List<T>> ask<T>(
    SearchResultType type,
    Future<List<T>> Function() fetch,
  ) async {
    if (filter != null && filter != type) return <T>[];
    try {
      return await fetch();
    } on Object catch (error) {
      failed++;
      AppLogger.debug('Search: Deezer ${type.name} search failed: $error');
      return <T>[];
    }
  }

  Future<DeezerSearchHits?> run() async {
    final artists = ask(
      SearchResultType.artists,
      () => catalog.searchArtists(query, cancelToken: cancelToken),
    );
    final albums = ask(
      SearchResultType.albums,
      () => catalog.searchAlbums(query, cancelToken: cancelToken),
    );
    final tracks = ask(
      SearchResultType.songs,
      () => catalog.searchTracks(query, cancelToken: cancelToken),
    );
    final hits = DeezerSearchHits(
      artists: await artists,
      albums: await albums,
      tracks: await tracks,
    );
    if (!cancelToken.isCancelled) {
      recorder.span(kSearchDeezerSpan, <String, int>{
        'artists': hits.artists.length,
        'albums': hits.albums.length,
        'tracks': hits.tracks.length,
        'failed': failed,
      }, timer.elapsed);
    }
    return hits;
  }

  return run();
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
    case SearchResultType.playlists:
    case SearchResultType.radio:
      return const SearchResult3();
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

enum SearchResultType {
  artists,
  albums,
  songs,
  playlists,
  radio;

  /// Playlists and radio stations are matched in memory, not by `search3`.
  bool get isCollection => this == playlists || this == radio;
}

/// Saved playlists and radio stations matching the current search query.
@immutable
class SearchCollectionMatches {
  const new({
    this.playlists = const <PlaylistsTableData>[],
    this.stations = const <InternetRadioStation>[],
  });

  final List<PlaylistsTableData> playlists;
  final List<InternetRadioStation> stations;
}

/// Playlists (device and server, from the Drift cache) and radio stations
/// (device first, then server) whose name matches the query, best match first.
///
/// Matching and ranking reuse [searchRelevanceTier]. Sources are read with
/// `.value`, so a loading, reloading, failed or offline list never throws or
/// drops the rows it last had; device playlists and device stations always
/// stay searchable.
final searchCollectionMatchesProvider =
    Provider.autoDispose<SearchCollectionMatches>((ref) {
      final query = ref.watch(searchQueryProvider).trim();
      if (query.isEmpty) {
        return const SearchCollectionMatches();
      }
      return SearchCollectionMatches(
        playlists: _matchByName(
          ref.watch(playlistListProvider).value ?? const <PlaylistsTableData>[],
          (p) => p.name,
          query,
        ),
        stations: _matchByName(
          <InternetRadioStation>[
            ...?ref.watch(localRadioStationsProvider).value,
            ...?ref.watch(radioStationsProvider).value,
          ],
          (s) => s.name,
          query,
        ),
      );
    });

List<T> _matchByName<T>(List<T> items, String Function(T) name, String query) {
  final tiers = <SearchRelevanceTier>[
    for (final item in items) searchRelevanceTier(name(item), query),
  ];
  final order =
      <int>[
        for (var i = 0; i < items.length; i++)
          if (tiers[i] != SearchRelevanceTier.other) i,
      ]..sort((a, b) {
        final byTier = tiers[a].index.compareTo(tiers[b].index);
        return byTier != 0 ? byTier : a.compareTo(b);
      });
  return <T>[for (final i in order) items[i]];
}
