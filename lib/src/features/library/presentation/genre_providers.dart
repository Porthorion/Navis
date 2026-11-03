import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Changes whenever a library sync publishes or finishes, the same signal the
/// sync status banner follows. Genre queries are one-shot reads (the genre
/// index is rebuilt at the end of a sync), so they re-read on this instead of
/// watching `songs`, which every star and play-count write touches.
final genreDataEpochProvider = Provider.autoDispose<Object?>(
  (ref) => ref.watch(
    librarySyncControllerProvider.select(
      (sync) => (sync.lastCatalogUpdatedAt, sync.completedAt),
    ),
  ),
);

typedef GenreListRequest = ({
  String query,
  GenreSortOrder sort,
  bool downloadedOnly,
});

/// The merged genres of the library for the Genres page.
final genreListProvider = FutureProvider.autoDispose
    .family<List<GenreSummary>, GenreListRequest>((ref, request) {
      ref.watch(genreDataEpochProvider);
      if (request.downloadedOnly) ref.watch(downloadedContentIdsProvider);
      return ref
          .watch(navisDatabaseProvider)
          .libraryDao
          .getGenres(
            query: request.query,
            sort: request.sort,
            downloadedOnly: request.downloadedOnly,
          );
    });

/// Whether the library has not finished the sync that reads genre tags yet,
/// so an empty Genres page means "not yet" rather than "none".
final genresPendingSyncProvider = FutureProvider.autoDispose<bool>((ref) async {
  ref.watch(genreDataEpochProvider);
  final built = await ref
      .watch(navisDatabaseProvider)
      .appSettingsDao
      .getLastFullSyncAppBuild();
  return built != currentLibrarySyncModelVersion;
});

/// One genre with its unfiltered counts, for the detail header.
final genreSummaryProvider = FutureProvider.autoDispose
    .family<GenreSummary?, String>((ref, key) {
      ref.watch(genreDataEpochProvider);
      return ref.watch(navisDatabaseProvider).libraryDao.getGenre(key);
    });

typedef GenreAlbumsRequest = ({
  String key,
  AlbumSortOrder sort,
  bool downloadedOnly,
  String query,
  int limit,
});

/// The first `limit` albums of a genre; the grid asks for a larger limit as
/// it scrolls, like the Albums page.
final genreAlbumsProvider = FutureProvider.autoDispose
    .family<List<AlbumsTableData>, GenreAlbumsRequest>((ref, request) {
      ref.watch(genreDataEpochProvider);
      if (request.downloadedOnly) ref.watch(downloadedContentIdsProvider);
      return ref
          .watch(navisDatabaseProvider)
          .libraryDao
          .getAlbumsByGenre(
            request.key,
            sort: request.sort,
            downloadedOnly: request.downloadedOnly,
            query: request.query,
            limit: request.limit,
          );
    });

typedef GenreSongsRequest = ({
  String key,
  GenreSongSort sort,
  bool downloadedOnly,
  String query,
  int limit,
});

/// The first `limit` songs of a genre.
final genreSongsProvider = FutureProvider.autoDispose
    .family<List<SongsTableData>, GenreSongsRequest>((ref, request) {
      ref.watch(genreDataEpochProvider);
      if (request.downloadedOnly) ref.watch(downloadedContentIdsProvider);
      return ref
          .watch(navisDatabaseProvider)
          .libraryDao
          .getSongsByGenre(
            request.key,
            sort: request.sort,
            downloadedOnly: request.downloadedOnly,
            query: request.query,
            limit: request.limit,
          );
    });
