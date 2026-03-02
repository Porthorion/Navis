import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Starred / liked songs from local DB (limit 5 for home preview).
final homeLikedSongsProvider = StreamProvider<List<SongsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchStarredSongs(limit: 5);
});

/// Recently added albums from the server API.
final homeRecentlyAddedProvider = FutureProvider<List<Album>>((ref) async {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return const <Album>[];
  }

  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);

  return api.getAlbumList2(
    type: 'newest',
    size: 20,
    cancelToken: cancelToken,
  );
});

/// Recently played **albums** derived from local play history.
final homeRecentlyPlayedAlbumsProvider = StreamProvider<List<AlbumsTableData>>((
  ref,
) {
  final dao = ref.watch(navisDatabaseProvider).historyDao;
  return dao.watchRecentlyPlayedAlbums(limit: 20);
});

/// Random albums from the server API.
final homeRandomAlbumsProvider = FutureProvider<List<Album>>((ref) async {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return const <Album>[];
  }

  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);

  return api.getAlbumList2(
    type: 'random',
    size: 20,
    cancelToken: cancelToken,
  );
});

/// Most played songs from local DB ordered by playCount (limit 5).
final homeMostPlayedSongsProvider = StreamProvider<List<SongsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  return dao.watchMostPlayedSongs(limit: 5);
});

final homeDownloadedLikedSongsProvider = StreamProvider<List<SongsTableData>>((
  ref,
) {
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  final downloadedSongIds =
      ref.watch(downloadedSongIdsProvider).asData?.value ?? const <String>{};
  return dao.watchAllStarredSongs().map(
    (songs) => songs
        .where((song) => downloadedSongIds.contains(song.id))
        .take(5)
        .toList(growable: false),
  );
});

final homeDownloadedRecentlyAddedAlbumsProvider =
    StreamProvider<List<AlbumsTableData>>((ref) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      final downloadedAlbumIds =
          ref.watch(downloadedContentIdsProvider).asData?.value.albumIds ??
          const <String>{};
      return dao
          .watchAlbumsSorted(sort: AlbumSortOrder.recentlyAdded)
          .map(
            (albums) => albums
                .where((album) => downloadedAlbumIds.contains(album.id))
                .take(20)
                .toList(growable: false),
          );
    });

final homeDownloadedRecentlyPlayedAlbumsProvider =
    StreamProvider<List<AlbumsTableData>>((ref) {
      final dao = ref.watch(navisDatabaseProvider).historyDao;
      final downloadedAlbumIds =
          ref.watch(downloadedContentIdsProvider).asData?.value.albumIds ??
          const <String>{};
      return dao
          .watchRecentlyPlayedAlbums(limit: null)
          .map(
            (albums) => albums
                .where((album) => downloadedAlbumIds.contains(album.id))
                .take(20)
                .toList(growable: false),
          );
    });

final homeDownloadedRandomAlbumsProvider =
    StreamProvider<List<AlbumsTableData>>((
      ref,
    ) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      final downloadedAlbumIds =
          ref.watch(downloadedContentIdsProvider).asData?.value.albumIds ??
          const <String>{};
      final random = Random();
      return dao.watchAlbumsSorted(sort: AlbumSortOrder.name).map((albums) {
        final filtered = albums
            .where((album) => downloadedAlbumIds.contains(album.id))
            .toList(growable: true);
        filtered.shuffle(random);
        return filtered.take(20).toList(growable: false);
      });
    });

final homeDownloadedMostPlayedSongsProvider =
    StreamProvider<List<SongsTableData>>((
      ref,
    ) {
      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      final downloadedSongIds =
          ref.watch(downloadedSongIdsProvider).asData?.value ??
          const <String>{};
      return dao
          .watchMostPlayedSongs(limit: null)
          .map(
            (songs) => songs
                .where((song) => downloadedSongIds.contains(song.id))
                .take(5)
                .toList(growable: false),
          );
    });

// ---------------------------------------------------------------------------
// Kept for backwards compat / possible future use — can be removed later.
// ---------------------------------------------------------------------------

final homeRecentlyPlayedProvider = StreamProvider<List<SongsTableData>>((ref) {
  final dao = ref.watch(navisDatabaseProvider).historyDao;
  return dao.watchRecentlyPlayedSongs(limit: 20);
});

final homeFrequentAlbumsProvider = FutureProvider<List<Album>>((ref) async {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return const <Album>[];
  }

  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);

  return api.getAlbumList2(
    type: 'frequent',
    size: 20,
    cancelToken: cancelToken,
  );
});

final homeStarredSongsProvider = FutureProvider<List<Song>>((ref) async {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return const <Song>[];
  }

  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);

  return (await api.getStarred2(cancelToken: cancelToken)).songs;
});
