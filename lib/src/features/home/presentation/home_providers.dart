import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/features/player/domain/lyrics_matcher.dart';

enum HomeRandomShowcaseSource { likedDiscovery, serverRandom, localFallback }

class HomeRandomShowcaseAlbum {
  const HomeRandomShowcaseAlbum({
    required this.id,
    required this.name,
    required this.source,
    this.artist,
    this.coverArtId,
    this.year,
    this.songCount,
  });

  factory HomeRandomShowcaseAlbum.fromServer(Album album) {
    return HomeRandomShowcaseAlbum(
      id: album.id,
      name: album.name,
      artist: album.artist,
      coverArtId: album.coverArt,
      year: album.year,
      songCount: album.songCount,
      source: HomeRandomShowcaseSource.serverRandom,
    );
  }

  factory HomeRandomShowcaseAlbum.fromLocal(AlbumsTableData album) {
    return HomeRandomShowcaseAlbum(
      id: album.id,
      name: album.name,
      artist: album.artistName,
      coverArtId: album.coverArt,
      year: album.year,
      songCount: album.songCount,
      source: HomeRandomShowcaseSource.localFallback,
    );
  }

  factory HomeRandomShowcaseAlbum.fromLocalDiscovery(AlbumsTableData album) {
    return HomeRandomShowcaseAlbum(
      id: album.id,
      name: album.name,
      artist: album.artistName,
      coverArtId: album.coverArt,
      year: album.year,
      songCount: album.songCount,
      source: HomeRandomShowcaseSource.likedDiscovery,
    );
  }

  factory HomeRandomShowcaseAlbum.fromSimilarSong(Song song) {
    final albumId = song.albumId?.trim();
    final albumName = song.album?.trim();
    return HomeRandomShowcaseAlbum(
      id: albumId ?? song.id,
      name: (albumName != null && albumName.isNotEmpty)
          ? albumName
          : song.title,
      artist: song.artist,
      coverArtId: song.coverArt,
      year: song.year,
      source: HomeRandomShowcaseSource.likedDiscovery,
    );
  }

  final String id;
  final String name;
  final String? artist;
  final String? coverArtId;
  final int? year;
  final int? songCount;
  final HomeRandomShowcaseSource source;
}

const int _homeRandomShowcaseLimit = 12;
const int _homeRandomDiscoverySeedCount = 3;
const int _homeRandomDiscoveryMinLikedSongs = 5;
const int _homeRandomDiscoverySongCountPerSeed = 20;
const int _homeRandomDiscoveryMinResults = 6;
const int _listenBrainzDiscoverPlaylistLimit = 6;
const int _listenBrainzDiscoverTrackPreviewLimit = 35;
const int _listenBrainzDiscoverSearchSongCount = 8;
const int _listenBrainzDiscoverResolutionParallelism = 3;
const double _listenBrainzDiscoverMinimumScore = 0.76;
const double _listenBrainzDiscoverAmbiguousDelta = 0.03;

List<ListenBrainzDiscoverPlaylist>? _listenBrainzDiscoverSessionCache;

enum ListenBrainzRecommendationMatchStatus { matched, unmatched, ambiguous }

class ListenBrainzResolvedRecommendation {
  const ListenBrainzResolvedRecommendation({
    required this.track,
    required this.status,
    this.song,
  });

  final ListenBrainzPlaylistTrack track;
  final ListenBrainzRecommendationMatchStatus status;
  final Song? song;

  bool get isPlayable =>
      status == ListenBrainzRecommendationMatchStatus.matched && song != null;
}

class ListenBrainzDiscoverPlaylist {
  const ListenBrainzDiscoverPlaylist({
    required this.playlist,
    required this.recommendations,
  });

  final ListenBrainzPlaylist playlist;
  final List<ListenBrainzResolvedRecommendation> recommendations;

  int get totalCount => recommendations.length;
  int get matchedCount => playableSongs.length;

  List<Song> get playableSongs => recommendations
      .where((recommendation) => recommendation.isPlayable)
      .map((recommendation) => recommendation.song!)
      .toList(growable: false);
}

class HomeRandomShowcaseShuffleSeedNotifier extends Notifier<int> {
  @override
  int build() => Random().nextInt(1 << 31);

  void reshuffle() {
    state = Random().nextInt(1 << 31);
  }
}

final homeRandomShowcaseShuffleSeedProvider =
    NotifierProvider<HomeRandomShowcaseShuffleSeedNotifier, int>(
      HomeRandomShowcaseShuffleSeedNotifier.new,
    );

final listenBrainzDiscoverProvider =
    FutureProvider<List<ListenBrainzDiscoverPlaylist>>((ref) async {
      final settings =
          ref.watch(appSettingsProvider).asData?.value ??
          const AppSettingsModel.defaults();
      if (!settings.listenBrainzTokenValid) {
        return const <ListenBrainzDiscoverPlaylist>[];
      }

      final userName = settings.listenBrainzUserName?.trim();
      if (userName == null || userName.isEmpty) {
        return const <ListenBrainzDiscoverPlaylist>[];
      }

      final token =
          (await ref
                  .read(externalScrobbleCredentialStoreProvider)
                  .readListenBrainzToken())
              ?.trim() ??
          '';
      if (token.isEmpty) {
        return const <ListenBrainzDiscoverPlaylist>[];
      }

      if (ref.watch(networkTypeProvider) == NetworkType.offline) {
        return _listenBrainzDiscoverSessionCache ??
            const <ListenBrainzDiscoverPlaylist>[];
      }

      final client = ref.read(listenBrainzApiClientProvider);
      final api = ref.read(subsonicApiProvider);
      if (api == null) {
        return const <ListenBrainzDiscoverPlaylist>[];
      }

      try {
        final playlistMetadata = await client.getRecommendationPlaylists(
          userName: userName,
          userToken: token,
        );
        final cappedMetadata = playlistMetadata
            .take(_listenBrainzDiscoverPlaylistLimit)
            .toList(growable: false);
        final resolvedPlaylists = <ListenBrainzDiscoverPlaylist>[];
        for (final metadata in cappedMetadata) {
          final identifier = metadata.identifier.trim();
          if (identifier.isEmpty) {
            continue;
          }
          final playlist = await client.getPlaylist(
            identifier,
            fetchMetadata: true,
            userToken: token,
          );
          final tracks = playlist.tracks
              .take(_listenBrainzDiscoverTrackPreviewLimit)
              .toList(growable: false);
          final resolved = await _resolveListenBrainzTracks(api, tracks);
          resolvedPlaylists.add(
            ListenBrainzDiscoverPlaylist(
              playlist: playlist,
              recommendations: resolved,
            ),
          );
        }
        _listenBrainzDiscoverSessionCache = resolvedPlaylists;
        return resolvedPlaylists;
      } on DioException catch (error) {
        final status = error.response?.statusCode;
        if (status == 401 || status == 403) {
          await ref
              .read(navisDatabaseProvider)
              .appSettingsDao
              .updateListenBrainzScrobblingState(
                enabled: false,
                tokenValid: false,
                clearUserName: true,
              );
          return const <ListenBrainzDiscoverPlaylist>[];
        }
        if (_listenBrainzDiscoverSessionCache != null) {
          return _listenBrainzDiscoverSessionCache!;
        }
        rethrow;
      }
    });

Future<List<ListenBrainzResolvedRecommendation>> _resolveListenBrainzTracks(
  SubsonicApiClient api,
  List<ListenBrainzPlaylistTrack> tracks,
) async {
  final resolved = List<ListenBrainzResolvedRecommendation?>.filled(
    tracks.length,
    null,
  );

  for (
    var batchStart = 0;
    batchStart < tracks.length;
    batchStart += _listenBrainzDiscoverResolutionParallelism
  ) {
    final batchEnd = min(
      tracks.length,
      batchStart + _listenBrainzDiscoverResolutionParallelism,
    );
    await Future.wait(
      Iterable<int>.generate(batchEnd - batchStart, (i) => batchStart + i).map(
        (index) async {
          final track = tracks[index];
          try {
            final query = <String>[
              track.title,
              if (track.creator != null) track.creator!,
              if (track.album != null) track.album!,
            ].join(' ');
            final search = await api.search3(
              query: query,
              artistCount: 0,
              albumCount: 0,
              songCount: _listenBrainzDiscoverSearchSongCount,
            );
            resolved[index] = _pickListenBrainzTrackMatch(track, search.songs);
          } on Object {
            resolved[index] = ListenBrainzResolvedRecommendation(
              track: track,
              status: ListenBrainzRecommendationMatchStatus.unmatched,
            );
          }
        },
      ),
    );
  }

  return resolved.whereType<ListenBrainzResolvedRecommendation>().toList(
    growable: false,
  );
}

ListenBrainzResolvedRecommendation _pickListenBrainzTrackMatch(
  ListenBrainzPlaylistTrack track,
  List<Song> candidates,
) {
  final expectedTitle = normalizeMetadata(track.title);
  final expectedArtist = normalizeMetadata(track.creator ?? '');
  if (expectedTitle.isEmpty || expectedArtist.isEmpty || candidates.isEmpty) {
    return ListenBrainzResolvedRecommendation(
      track: track,
      status: ListenBrainzRecommendationMatchStatus.unmatched,
    );
  }

  final scored = <({Song song, double score})>[];
  for (final candidate in candidates) {
    final candidateTitle = normalizeMetadata(candidate.title);
    final candidateArtist = normalizeMetadata(candidate.artist ?? '');
    if (candidateTitle.isEmpty || candidateArtist.isEmpty) {
      continue;
    }
    final titleScore = _listenBrainzFieldScore(expectedTitle, candidateTitle);
    final artistScore = _listenBrainzFieldScore(
      expectedArtist,
      candidateArtist,
    );
    if (artistScore < 0.35) {
      continue;
    }
    var score = (titleScore * 0.58) + (artistScore * 0.32);
    final expectedAlbum = normalizeMetadata(track.album ?? '');
    final candidateAlbum = normalizeMetadata(candidate.album ?? '');
    if (expectedAlbum.isNotEmpty && candidateAlbum.isNotEmpty) {
      score += _listenBrainzFieldScore(expectedAlbum, candidateAlbum) * 0.06;
    }
    final expectedDuration = track.durationSeconds;
    final candidateDuration = candidate.duration;
    if (expectedDuration != null && candidateDuration != null) {
      final diff = (expectedDuration - candidateDuration).abs();
      if (diff <= 3) {
        score += 0.04;
      } else if (diff > 15) {
        score -= 0.08;
      }
    }
    scored.add((song: candidate, score: score.clamp(0.0, 1.0)));
  }

  scored.sort((a, b) => b.score.compareTo(a.score));
  if (scored.isEmpty ||
      scored.first.score < _listenBrainzDiscoverMinimumScore) {
    return ListenBrainzResolvedRecommendation(
      track: track,
      status: ListenBrainzRecommendationMatchStatus.unmatched,
    );
  }
  if (scored.length > 1 &&
      scored.first.score - scored[1].score <
          _listenBrainzDiscoverAmbiguousDelta &&
      scored.first.song.id != scored[1].song.id) {
    return ListenBrainzResolvedRecommendation(
      track: track,
      status: ListenBrainzRecommendationMatchStatus.ambiguous,
    );
  }
  return ListenBrainzResolvedRecommendation(
    track: track,
    status: ListenBrainzRecommendationMatchStatus.matched,
    song: scored.first.song,
  );
}

double _listenBrainzFieldScore(String expected, String actual) {
  if (expected == actual) {
    return 1;
  }
  if (actual.contains(expected) || expected.contains(actual)) {
    return 0.82;
  }
  final expectedTokens = expected.split(' ').where((t) => t.length > 1).toSet();
  final actualTokens = actual.split(' ').where((t) => t.length > 1).toSet();
  if (expectedTokens.isEmpty || actualTokens.isEmpty) {
    return 0;
  }
  final overlap = expectedTokens.intersection(actualTokens).length;
  return overlap / expectedTokens.length;
}

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

final homeRandomShowcaseProvider =
    FutureProvider.family<
      List<HomeRandomShowcaseAlbum>,
      ({bool downloadedOnly, bool likedOnly})
    >((ref, filters) async {
      final downloadedOnly = filters.downloadedOnly;
      final likedOnly = filters.likedOnly;
      final networkType = ref.watch(networkTypeProvider);
      final shuffleSeed = ref.watch(homeRandomShowcaseShuffleSeedProvider);
      final localPreferred =
          downloadedOnly || likedOnly || networkType == NetworkType.offline;

      final dao = ref.watch(navisDatabaseProvider).libraryDao;
      final allAlbums = await dao.getAllAlbums();

      final downloadedAlbumIds = downloadedOnly
          ? (ref.watch(downloadedContentIdsProvider).asData?.value.albumIds ??
                const <String>{})
          : const <String>{};
      final scopedAlbums = downloadedOnly
          ? allAlbums
                .where((album) => downloadedAlbumIds.contains(album.id))
                .toList(growable: false)
          : allAlbums;
      final scopedById = <String, AlbumsTableData>{
        for (final album in scopedAlbums) album.id: album,
      };
      // Intentional non-reactive snapshot: liking/unliking a song should not
      // reshuffle the random showcase unless an explicit refresh/sync occurs.
      final likedSongsSnapshot =
          ref.read(likedSongsProvider).asData?.value ??
          const <SongsTableData>[];

      if (!localPreferred) {
        final api = ref.watch(subsonicApiProvider);
        if (api != null) {
          final eligibleLikedSongs = likedSongsSnapshot
              .where((song) => song.id.trim().isNotEmpty)
              .toList(growable: true);

          if (eligibleLikedSongs.length >= _homeRandomDiscoveryMinLikedSongs) {
            final discovery = await _buildLikedDiscoveryAlbums(
              api: api,
              likedSongs: eligibleLikedSongs,
              scopedById: scopedById,
              shuffleSeed: shuffleSeed,
            );
            if (discovery.length >= _homeRandomDiscoveryMinResults) {
              return discovery
                  .take(_homeRandomShowcaseLimit)
                  .toList(growable: false);
            }
          }

          try {
            final serverRandom = await ref.watch(
              homeRandomAlbumsProvider.future,
            );
            if (serverRandom.isNotEmpty) {
              return serverRandom
                  .take(_homeRandomShowcaseLimit)
                  .map(HomeRandomShowcaseAlbum.fromServer)
                  .toList(growable: false);
            }
          } on Exception {
            // Fall back to local candidates when server random fails.
          }
        }
      }

      final candidates = <AlbumsTableData>[];
      if (likedOnly) {
        final deduped = <String, AlbumsTableData>{};

        final likedAlbums = await dao.getLikedAlbums();
        for (final likedAlbum in likedAlbums) {
          final scopedAlbum = scopedById[likedAlbum.id];
          if (scopedAlbum == null) {
            continue;
          }
          deduped[scopedAlbum.id] = scopedAlbum;
        }

        if (deduped.length < _homeRandomShowcaseLimit) {
          final downloadedSongIds = downloadedOnly
              ? (ref.watch(downloadedSongIdsProvider).asData?.value ??
                    const <String>{})
              : const <String>{};

          for (final song in likedSongsSnapshot) {
            if (downloadedOnly && !downloadedSongIds.contains(song.id)) {
              continue;
            }
            final albumId = song.albumId?.trim();
            if (albumId == null || albumId.isEmpty) {
              continue;
            }
            final scopedAlbum = scopedById[albumId];
            if (scopedAlbum == null) {
              continue;
            }
            deduped[scopedAlbum.id] = scopedAlbum;
          }
        }

        candidates.addAll(deduped.values);
      } else {
        candidates.addAll(scopedAlbums);
      }

      final random = Random(
        shuffleSeed ^
            (downloadedOnly ? 0x9e3779b9 : 0) ^
            (likedOnly ? 0x7f4a7c15 : 0) ^
            candidates.length,
      );
      candidates.shuffle(random);
      return candidates
          .take(_homeRandomShowcaseLimit)
          .map(HomeRandomShowcaseAlbum.fromLocal)
          .toList(growable: false);
    });

Future<List<HomeRandomShowcaseAlbum>> _buildLikedDiscoveryAlbums({
  required SubsonicApiClient api,
  required List<SongsTableData> likedSongs,
  required Map<String, AlbumsTableData> scopedById,
  required int shuffleSeed,
}) async {
  final likedAlbumIds = likedSongs
      .map((song) => song.albumId?.trim())
      .whereType<String>()
      .where((id) => id.isNotEmpty)
      .toSet();
  if (likedAlbumIds.isEmpty) {
    return const <HomeRandomShowcaseAlbum>[];
  }

  final seedPool = likedSongs.toList(growable: true);
  seedPool.shuffle(Random(shuffleSeed ^ 0x1f123bb5));
  final seedSongs = seedPool
      .where((song) => song.id.trim().isNotEmpty)
      .take(_homeRandomDiscoverySeedCount)
      .toList(growable: false);
  if (seedSongs.isEmpty) {
    return const <HomeRandomShowcaseAlbum>[];
  }

  final unseenCandidates = <String, HomeRandomShowcaseAlbum>{};
  final knownCandidates = <String, HomeRandomShowcaseAlbum>{};

  for (final seed in seedSongs) {
    List<Song> similarSongs;
    try {
      similarSongs = await api.getSimilarSongs(
        seed.id,
        count: _homeRandomDiscoverySongCountPerSeed,
      );
    } on Exception {
      continue;
    }

    for (final song in similarSongs) {
      final albumId = song.albumId?.trim();
      if (albumId == null || albumId.isEmpty) {
        continue;
      }
      if (unseenCandidates.containsKey(albumId) ||
          knownCandidates.containsKey(albumId)) {
        continue;
      }

      final scopedAlbum = scopedById[albumId];
      final showcaseAlbum = scopedAlbum != null
          ? HomeRandomShowcaseAlbum.fromLocalDiscovery(scopedAlbum)
          : HomeRandomShowcaseAlbum.fromSimilarSong(song);
      if (likedAlbumIds.contains(albumId)) {
        knownCandidates[albumId] = showcaseAlbum;
      } else {
        unseenCandidates[albumId] = showcaseAlbum;
      }
    }
  }

  return <HomeRandomShowcaseAlbum>[
    ...unseenCandidates.values,
    ...knownCandidates.values,
  ];
}

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
