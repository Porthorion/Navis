import 'package:dio/dio.dart';

import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/features/integrations/data/deezer_artist_resolver.dart';
import 'package:navis/src/features/integrations/data/deezer_cache.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/features/library/domain/artist_top_track.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/metadata_normalization.dart';

/// Most top songs kept for an artist (the "This Is" playlist length).
const int kArtistTopTrackSeedMax = 50;

/// Tracks requested from Deezer's search when `/artist/{id}/top` is empty.
const int kDeezerTopTrackSearchLimit = 100;

/// Last.fm top songs per normalized artist name.
const String kLastFmTopTracksCacheNamespace = 'lastfm.artist-top-tracks';

/// The top songs of one artist and whether they came from the disk cache.
typedef ArtistTopTrackSeedsLoad = ({
  List<ArtistTopTrackSeed> seeds,
  bool cacheHit,
});

/// Loads an artist's top songs: Deezer first, then Last.fm, then none.
///
/// Each source is used only when its flag says the policy allows it, and a
/// source that fails or has nothing for the artist hands over to the next.
/// Results are cached for 24 hours per source.
class ArtistTopTrackSources {
  new({required this._cache, this.deezer, this.deezerArtists, this.lastFm});

  final IntegrationJsonCache _cache;
  final DeezerApiClient? deezer;
  final DeezerArtistResolver? deezerArtists;
  final LastFmApiClient? lastFm;

  Future<ArtistTopTrackSeedsLoad> load({
    required String artistId,
    required String artistName,
    required bool deezerAllowed,
    required bool lastFmAllowed,
    Future<Iterable<String>> Function()? readLibraryAlbumTitles,
    CancelToken? cancelToken,
  }) async {
    const none = (seeds: <ArtistTopTrackSeed>[], cacheHit: false);
    final name = artistName.trim();
    if (name.isEmpty) return none;

    if (deezerAllowed) {
      try {
        final fromDeezer = await _loadFromDeezer(
          artistId: artistId,
          name: name,
          readLibraryAlbumTitles: readLibraryAlbumTitles,
          cancelToken: cancelToken,
        );
        if (fromDeezer != null && fromDeezer.seeds.isNotEmpty) {
          return fromDeezer;
        }
      } on Object catch (error) {
        AppLogger.debug('Top songs: Deezer failed, trying Last.fm: $error');
      }
      if (cancelToken?.isCancelled ?? false) return none;
    }
    if (lastFmAllowed) {
      return await _loadFromLastFm(name);
    }
    return none;
  }

  /// Null when Deezer has no artist of this name.
  Future<ArtistTopTrackSeedsLoad?> _loadFromDeezer({
    required String artistId,
    required String name,
    required Future<Iterable<String>> Function()? readLibraryAlbumTitles,
    required CancelToken? cancelToken,
  }) async {
    final client = deezer;
    final resolver = deezerArtists;
    if (client == null || resolver == null) return null;
    final deezerId = await resolver.resolve(
      artistId: artistId,
      name: name,
      readLibraryAlbumTitles: readLibraryAlbumTitles,
      cancelToken: cancelToken,
    );
    if (deezerId == null) return null;

    final cacheKey = '$deezerId';
    final cached = await _cache.read(
      DeezerCache.artistTopTracksNamespace,
      cacheKey,
    );
    if (cached != null && cached.value is List) {
      final tracks = (cached.value! as List)
          .whereType<Map<Object?, Object?>>()
          .map((json) => DeezerTrack.fromJson(Map<String, dynamic>.from(json)))
          .toList(growable: false);
      return (seeds: _deezerSeeds(tracks), cacheHit: true);
    }

    var tracks = rankDeezerArtistTracks(
      await client.getArtistTopTracks(
        deezerId,
        limit: kArtistTopTrackSeedMax,
        cancelToken: cancelToken,
      ),
      deezerArtistId: deezerId,
    );
    if (tracks.isEmpty) {
      // `/artist/{id}/top` is empty in some regions for every artist.
      tracks = rankDeezerArtistTracks(
        await client.searchTracks(
          name,
          limit: kDeezerTopTrackSearchLimit,
          cancelToken: cancelToken,
        ),
        deezerArtistId: deezerId,
      );
    }
    tracks = tracks.take(kArtistTopTrackSeedMax).toList(growable: false);
    await _cache.write(
      DeezerCache.artistTopTracksNamespace,
      cacheKey,
      tracks.map((track) => track.toJson()).toList(growable: false),
      ttl: DeezerCache.trackSearchTtl,
    );
    return (seeds: _deezerSeeds(tracks), cacheHit: false);
  }

  Future<ArtistTopTrackSeedsLoad> _loadFromLastFm(String name) async {
    final cacheKey = name.toLowerCase();
    final cached = await _cache.read(kLastFmTopTracksCacheNamespace, cacheKey);
    if (cached != null && cached.value is List) {
      try {
        final seeds = (cached.value! as List)
            .whereType<Map<Object?, Object?>>()
            .map(
              (json) =>
                  ArtistTopTrackSeed.fromJson(Map<String, dynamic>.from(json)),
            )
            .toList(growable: false);
        if (seeds.isNotEmpty) return (seeds: seeds, cacheHit: true);
      } on Object catch (error) {
        AppLogger.debug('Top songs: unreadable Last.fm cache entry: $error');
      }
    }

    final client = lastFm;
    if (client == null) {
      return (seeds: const <ArtistTopTrackSeed>[], cacheHit: false);
    }
    final tracks = await client.getArtistTopTracks(
      artist: name,
      limit: kArtistTopTrackSeedMax,
    );
    final seeds = tracks
        .map(
          (track) => ArtistTopTrackSeed(
            rank: track.rank,
            title: track.title,
            artist: track.artist,
            listeners: track.listeners,
            source: ArtistTopTrackSource.lastFm,
          ),
        )
        .toList(growable: false);
    if (seeds.isNotEmpty) {
      await _cache.write(
        kLastFmTopTracksCacheNamespace,
        cacheKey,
        seeds.map((seed) => seed.toJson()).toList(growable: false),
        ttl: const Duration(hours: 24),
      );
    }
    return (seeds: seeds, cacheHit: false);
  }

  static List<ArtistTopTrackSeed> _deezerSeeds(List<DeezerTrack> tracks) => [
    for (var i = 0; i < tracks.length; i++)
      ArtistTopTrackSeed(
        rank: i + 1,
        title: tracks[i].title,
        artist: tracks[i].artist.name,
        source: ArtistTopTrackSource.deezer,
        popularity: tracks[i].rank,
        album: tracks[i].album?.title,
        durationSeconds: tracks[i].durationSeconds,
        deezerTrackId: tracks[i].id,
      ),
  ];
}

/// [tracks] by the artist [deezerArtistId] only, most popular first, one per
/// edition.
///
/// Search results include covers and remixes by other artists, so the artist
/// id must match. Two tracks are the same song when their edition-preserving
/// title keys are equal, so "Wonder" and "Wonder (Japanese Version)" both
/// stay while a remaster folds into the original.
List<DeezerTrack> rankDeezerArtistTracks(
  List<DeezerTrack> tracks, {
  required int deezerArtistId,
}) {
  final byArtist = tracks
      .where((track) => track.artist.id == deezerArtistId)
      .toList(growable: false);
  final order = <DeezerTrack, int>{
    for (var i = 0; i < byArtist.length; i++) byArtist[i]: i,
  };
  final sorted = byArtist.toList()
    ..sort((a, b) {
      final byRank = (b.rank ?? -1).compareTo(a.rank ?? -1);
      return byRank != 0 ? byRank : order[a]!.compareTo(order[b]!);
    });
  final seen = <String>{};
  return [
    for (final track in sorted)
      if (seen.add(_editionKey(track))) track,
  ];
}

String _editionKey(DeezerTrack track) {
  final key = normalizeMetadataKeepingEdition(track.title);
  return key.isEmpty ? 'id:${track.id}' : key;
}
