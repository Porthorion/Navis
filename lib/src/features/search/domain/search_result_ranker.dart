import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/utils/catalog_source.dart';

enum SearchRelevanceTier { exact, prefix, substring, tokens, other }

SearchRelevanceTier searchRelevanceTier(String field, String query) {
  final normalizedField = field.toLowerCase();
  final normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) return SearchRelevanceTier.other;
  if (normalizedField == normalizedQuery) return SearchRelevanceTier.exact;
  if (normalizedField.startsWith(normalizedQuery)) {
    return SearchRelevanceTier.prefix;
  }
  if (normalizedField.contains(normalizedQuery)) {
    return SearchRelevanceTier.substring;
  }
  final words = normalizedQuery.split(RegExp(r'\s+'));
  if (words.length > 1 && words.every(normalizedField.contains)) {
    return SearchRelevanceTier.tokens;
  }
  return SearchRelevanceTier.other;
}

/// How popular Deezer finds the items of a search, by item id and type: 0 is
/// the most popular. An item missing here is unranked.
class SearchPopularity {
  const new({
    this.artists = const <String, int>{},
    this.albums = const <String, int>{},
    this.songs = const <String, int>{},
  });

  final Map<String, int> artists;
  final Map<String, int> albums;
  final Map<String, int> songs;
}

/// Orders unranked items after every ranked one.
const int _unranked = 1 << 30;

/// Ranks [result] by text relevance, then source and server order. With
/// [popularity], Deezer's rank breaks ties inside a relevance tier, ahead of
/// source: ranked items first by rank, unranked after. Without it, or with
/// nothing ranked, the order is exactly the one without popularity.
SearchResult3 rankSearchResult(
  SearchResult3 result,
  String query, {
  SearchPopularity? popularity,
}) {
  List<T> rank<T>(
    List<T> items,
    Map<String, int>? ranks, {
    required String Function(T) id,
    required String Function(T) label,
    required bool? Function(T) isExternal,
  }) {
    final indexed = List<(int, T)>.generate(
      items.length,
      (index) => (index, items[index]),
    );
    indexed.sort((left, right) {
      final leftItem = left.$2;
      final rightItem = right.$2;
      final relevanceDifference = searchRelevanceTier(
        label(leftItem),
        query,
      ).index.compareTo(searchRelevanceTier(label(rightItem), query).index);
      if (relevanceDifference != 0) return relevanceDifference;

      if (ranks != null && ranks.isNotEmpty) {
        final popularityDifference = (ranks[id(leftItem)] ?? _unranked)
            .compareTo(ranks[id(rightItem)] ?? _unranked);
        if (popularityDifference != 0) return popularityDifference;
      }

      final sourceDifference =
          classifyCatalogSource(
            id: id(leftItem),
            apiIsExternal: isExternal(leftItem),
          ).index.compareTo(
            classifyCatalogSource(
              id: id(rightItem),
              apiIsExternal: isExternal(rightItem),
            ).index,
          );
      if (sourceDifference != 0) return sourceDifference;
      return left.$1.compareTo(right.$1);
    });
    return indexed.map((item) => item.$2).toList(growable: false);
  }

  return SearchResult3(
    artists: rank(
      result.artists,
      popularity?.artists,
      id: (artist) => artist.id,
      label: (artist) => artist.name,
      isExternal: (artist) => artist.isExternal,
    ),
    albums: rank(
      result.albums,
      popularity?.albums,
      id: (album) => album.id,
      label: (album) => album.name,
      isExternal: (album) => album.isExternal,
    ),
    songs: rank(
      result.songs,
      popularity?.songs,
      id: (song) => song.id,
      label: (song) => song.title,
      isExternal: (song) => song.isExternal,
    ),
  );
}

SearchResult3 mergeAndRankSearchResults({
  required SearchResult3 local,
  required SearchResult3 api,
  required String query,
}) {
  List<T> merge<T>(
    List<T> localItems,
    List<T> apiItems,
    String Function(T) id,
    T Function(T local, T api) mergeDuplicate,
  ) {
    final apiById = <String, T>{for (final item in apiItems) id(item): item};
    final seen = <String>{};
    return <T>[
      for (final localItem in localItems)
        if (seen.add(id(localItem)))
          if (apiById[id(localItem)] == null)
            localItem
          else
            mergeDuplicate(localItem, apiById[id(localItem)] as T),
      ...apiItems.where((item) => seen.add(id(item))),
    ];
  }

  final merged = SearchResult3(
    artists: merge(
      local.artists,
      api.artists,
      (artist) => artist.id,
      (localItem, apiItem) => localItem.copyWith(
        isExternal: apiItem.isExternal ?? localItem.isExternal,
      ),
    ),
    albums: merge(
      local.albums,
      api.albums,
      (album) => album.id,
      (localItem, apiItem) => localItem.copyWith(
        isExternal: apiItem.isExternal ?? localItem.isExternal,
      ),
    ),
    songs: merge(
      local.songs,
      api.songs,
      (song) => song.id,
      (localItem, apiItem) => localItem.copyWith(
        isExternal: apiItem.isExternal ?? localItem.isExternal,
      ),
    ),
  );
  return rankSearchResult(merged, query);
}
