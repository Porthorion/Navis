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

/// Tracks requested from Deezer's search to fill a short top list.
const int kDeezerTopTrackSearchLimit = 100;

/// Below this many Deezer songs, Last.fm's songs are appended (when allowed).
const int kArtistTopTrackLastFmFillBelow = 10;

/// Last.fm top songs per normalized artist name.
const String kLastFmTopTracksCacheNamespace = 'lastfm.artist-top-tracks';

/// Layout of a `DeezerCache.artistTopTracksNamespace` entry. Entries written
/// before the search fill (a plain list) read as a miss.
const int _kDeezerTopTracksCacheVersion = 2;

/// An artist's top songs, whether every source answered from the disk
/// cache, and how many songs each step contributed.
typedef ArtistTopTrackSeedsLoad = ({
  List<ArtistTopTrackSeed> seeds,
  bool cacheHit,
  int fromTop,
  int fromSearch,
  int fromLastFm,
});

const ArtistTopTrackSeedsLoad _none = (
  seeds: <ArtistTopTrackSeed>[],
  cacheHit: false,
  fromTop: 0,
  fromSearch: 0,
  fromLastFm: 0,
);

/// Loads an artist's top songs (up to [kArtistTopTrackSeedMax]), each source
/// only when its flag says the policy allows it:
///
/// 1. Deezer's `/artist/{id}/top`. It returns no tracks in some regions and
///    only a handful for niche artists, so whenever it gives fewer than the
///    maximum, `/search/track` fills the list: tracks by the same Deezer
///    artist id, most popular first, skipping editions already listed.
/// 2. Last.fm: the whole list when Deezer has nothing or fails, or appended
///    (editions not already listed) when Deezer has fewer than
///    [kArtistTopTrackLastFmFillBelow]. Appended songs show no listener
///    count, so a mixed list does not show numbers on some rows only.
///
/// Each source caches its answer for 24 hours.
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
    bool Function()? readLastFmAllowed,
  }) async {
    final name = artistName.trim();
    if (name.isEmpty) return _none;

    _DeezerTopTracks? fromDeezer;
    if (deezerAllowed) {
      try {
        fromDeezer = await _loadFromDeezer(
          artistId: artistId,
          name: name,
          readLibraryAlbumTitles: readLibraryAlbumTitles,
          cancelToken: cancelToken,
        );
      } on Object catch (error) {
        AppLogger.debug('Top songs: Deezer failed, trying Last.fm: $error');
      }
      if (cancelToken?.isCancelled ?? false) return _none;
    }
    final deezerTracks = [...?fromDeezer?.top, ...?fromDeezer?.fill];
    final deezerSeeds = _deezerSeeds(deezerTracks);
    final deezerCached = fromDeezer?.cacheHit ?? false;
    if (deezerSeeds.length >= kArtistTopTrackLastFmFillBelow ||
        !lastFmAllowed) {
      if (deezerSeeds.isEmpty) return _none;
      return (
        seeds: deezerSeeds,
        cacheHit: deezerCached,
        fromTop: fromDeezer!.top.length,
        fromSearch: fromDeezer.fill.length,
        fromLastFm: 0,
      );
    }

    final lastFmLoad = await _loadFromLastFm(
      name,
      cancelToken,
      readLastFmAllowed,
    );
    if (deezerSeeds.isEmpty) {
      return (
        seeds: lastFmLoad.seeds,
        cacheHit: lastFmLoad.cacheHit,
        fromTop: 0,
        fromSearch: 0,
        fromLastFm: lastFmLoad.seeds.length,
      );
    }
    final listed = {
      for (final seed in deezerSeeds) _seedEditionKey(seed.title),
    };
    final appended = [
      for (final seed in lastFmLoad.seeds)
        if (listed.add(_seedEditionKey(seed.title))) seed,
    ].take(kArtistTopTrackSeedMax - deezerSeeds.length).toList();
    return (
      seeds: [
        ...deezerSeeds,
        for (var i = 0; i < appended.length; i++)
          ArtistTopTrackSeed(
            rank: deezerSeeds.length + i + 1,
            title: appended[i].title,
            artist: appended[i].artist,
            source: ArtistTopTrackSource.lastFm,
          ),
      ],
      cacheHit: deezerCached && lastFmLoad.cacheHit,
      fromTop: fromDeezer!.top.length,
      fromSearch: fromDeezer.fill.length,
      fromLastFm: appended.length,
    );
  }

  /// Null when Deezer has no artist of this name.
  Future<_DeezerTopTracks?> _loadFromDeezer({
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
    final cached = _DeezerTopTracks.fromCache(
      (await _cache.read(
        DeezerCache.artistTopTracksNamespace,
        cacheKey,
      ))?.value,
    );
    if (cached != null) return cached;

    final top = rankDeezerArtistTracks(
      await client.getArtistTopTracks(
        deezerId,
        limit: kArtistTopTrackSeedMax,
        cancelToken: cancelToken,
      ),
      deezerArtistId: deezerId,
    ).take(kArtistTopTrackSeedMax).toList(growable: false);
    var fill = const <DeezerTrack>[];
    if (top.length < kArtistTopTrackSeedMax) {
      try {
        final listed = {for (final track in top) _editionKey(track)};
        fill = [
          for (final track in rankDeezerArtistTracks(
            await client.searchTracks(
              name,
              limit: kDeezerTopTrackSearchLimit,
              cancelToken: cancelToken,
            ),
            deezerArtistId: deezerId,
          ))
            if (listed.add(_editionKey(track))) track,
        ].take(kArtistTopTrackSeedMax - top.length).toList(growable: false);
      } on Object catch (error) {
        if (cancelToken?.isCancelled ?? false) rethrow;
        if (error is DioException && CancelToken.isCancel(error)) rethrow;
        AppLogger.debug('Top songs: Deezer search fill failed: $error');
        return _DeezerTopTracks(top: top, fill: const [], cacheHit: false);
      }
    }

    final result = _DeezerTopTracks(top: top, fill: fill, cacheHit: false);
    await _cache.write(
      DeezerCache.artistTopTracksNamespace,
      cacheKey,
      result.toCache(),
      ttl: DeezerCache.trackSearchTtl,
    );
    return result;
  }

  Future<({List<ArtistTopTrackSeed> seeds, bool cacheHit})> _loadFromLastFm(
    String name,
    CancelToken? cancelToken,
    bool Function()? readAllowed,
  ) async {
    final cacheKey = name.toLowerCase();
    final cached = await _cache.read(kLastFmTopTracksCacheNamespace, cacheKey);
    if ((cancelToken?.isCancelled ?? false) || !(readAllowed?.call() ?? true)) {
      return (seeds: const <ArtistTopTrackSeed>[], cacheHit: false);
    }
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
      cancelToken: cancelToken,
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

String _seedEditionKey(String title) => normalizeMetadataKeepingEdition(title);

/// Deezer's answer for one artist: the `/artist/{id}/top` tracks, then the
/// `/search/track` tracks that fill the list.
class _DeezerTopTracks {
  const new({required this.top, required this.fill, required this.cacheHit});

  final List<DeezerTrack> top;
  final List<DeezerTrack> fill;
  final bool cacheHit;

  static _DeezerTopTracks? fromCache(Object? value) {
    if (value is! Map || value['v'] != _kDeezerTopTracksCacheVersion) {
      return null;
    }
    List<DeezerTrack> tracks(Object? list) => [
      if (list is List)
        for (final json in list.whereType<Map<Object?, Object?>>())
          DeezerTrack.fromJson(Map<String, dynamic>.from(json)),
    ];
    return _DeezerTopTracks(
      top: tracks(value['top']),
      fill: tracks(value['fill']),
      cacheHit: true,
    );
  }

  Map<String, Object?> toCache() => <String, Object?>{
    'v': _kDeezerTopTracksCacheVersion,
    'top': [for (final track in top) track.toJson()],
    'fill': [for (final track in fill) track.toJson()],
  };
}

String _editionKey(DeezerTrack track) {
  final key = normalizeMetadataKeepingEdition(track.title);
  return key.isEmpty ? 'id:${track.id}' : key;
}
