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

SearchResult3 rankSearchResult(SearchResult3 result, String query) {
  List<T> rank<T>(
    List<T> items, {
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
      id: (artist) => artist.id,
      label: (artist) => artist.name,
      isExternal: (artist) => artist.isExternal,
    ),
    albums: rank(
      result.albums,
      id: (album) => album.id,
      label: (album) => album.name,
      isExternal: (album) => album.isExternal,
    ),
    songs: rank(
      result.songs,
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
