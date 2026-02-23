import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';

class SearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  void submit(String value) => state = value;

  void clear() => state = '';
}

final searchQueryProvider = NotifierProvider<SearchQueryNotifier, String>(
  SearchQueryNotifier.new,
);

final recentSearchesProvider = StreamProvider<List<RecentSearchesTableData>>((
  ref,
) {
  final dao = ref.watch(navisDatabaseProvider).historyDao;
  return dao.watchRecentSearches(limit: 20);
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

  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return const SearchResult3();
  }

  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);

  return api.search3(
    query: query,
    artistCount: 20,
    albumCount: 20,
    songCount: 20,
    cancelToken: cancelToken,
  );
});

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
