import 'package:dio/dio.dart';

import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/features/integrations/data/deezer_cache.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Deezer artist and album data, read through the disk cache.
///
/// Each read returns the cached value while it is fresh and otherwise asks
/// Deezer and caches the answer for the [DeezerCache] lifetime of its kind:
/// artist details and related artists 7 days, an artist's albums 24 hours, an
/// album 7 days, the chart 6 hours. "Not on Deezer" is cached too. Request errors propagate and
/// are not cached. Callers check the feature switch first; the client's
/// guard checks only the service.
class DeezerCatalog {
  new({required this._client, required this._cache});

  /// Albums requested per artist; enough for any discography Navis shows.
  static const artistAlbumLimit = 100;

  /// Related artists requested per artist.
  static const relatedArtistLimit = 20;

  /// Releases requested per artist for New releases: Deezer lists recent
  /// releases first, so a few cover the last month.
  static const recentAlbumLimit = 5;

  /// Chart tracks requested for Trending.
  static const chartTrackLimit = 100;

  final DeezerApiClient _client;
  final IntegrationJsonCache _cache;

  /// `/artist/{id}`: photo and fan count.
  Future<DeezerArtist?> artist(int artistId, {CancelToken? cancelToken}) =>
      _cached(
        namespace: DeezerCache.artistDetailsNamespace,
        key: '$artistId',
        ttl: DeezerCache.artistDetailsTtl,
        fetch: () => _client.getArtist(artistId, cancelToken: cancelToken),
        encode: (artist) => artist?.toJson(),
        decode: (json) => json is Map
            ? DeezerArtist.fromJson(Map<String, dynamic>.from(json))
            : null,
      );

  /// `/artist/{id}/related`, most related first.
  Future<List<DeezerArtist>> relatedArtists(
    int artistId, {
    CancelToken? cancelToken,
  }) => _cached(
    namespace: DeezerCache.relatedArtistsNamespace,
    key: '$artistId',
    ttl: DeezerCache.relatedArtistsTtl,
    fetch: () => _client.getRelatedArtists(
      artistId,
      limit: relatedArtistLimit,
      cancelToken: cancelToken,
    ),
    encode: (artists) => [for (final artist in artists) artist.toJson()],
    decode: (json) => [
      if (json is List)
        for (final item in json.whereType<Map<Object?, Object?>>())
          DeezerArtist.fromJson(Map<String, dynamic>.from(item)),
    ],
  );

  /// `/artist/{id}/albums`: every release type, as Deezer orders them.
  Future<List<DeezerAlbum>> artistAlbums(
    int artistId, {
    CancelToken? cancelToken,
  }) => _cached(
    namespace: DeezerCache.artistAlbumsNamespace,
    key: '$artistId',
    ttl: DeezerCache.albumsTtl,
    fetch: () => _client.getArtistAlbums(
      artistId,
      limit: artistAlbumLimit,
      cancelToken: cancelToken,
    ),
    encode: (albums) => [for (final album in albums) album.toJson()],
    decode: (json) => [
      if (json is List)
        for (final item in json.whereType<Map<Object?, Object?>>())
          DeezerAlbum.fromJson(Map<String, dynamic>.from(item)),
    ],
  );

  /// The artist's first [recentAlbumLimit] releases (`/artist/{id}/albums`),
  /// cached 24 hours apart from the full list.
  Future<List<DeezerAlbum>> recentArtistAlbums(
    int artistId, {
    CancelToken? cancelToken,
  }) => _cached(
    namespace: DeezerCache.artistRecentAlbumsNamespace,
    key: '$artistId',
    ttl: DeezerCache.albumsTtl,
    fetch: () => _client.getArtistAlbums(
      artistId,
      limit: recentAlbumLimit,
      cancelToken: cancelToken,
    ),
    encode: (albums) => [for (final album in albums) album.toJson()],
    decode: (json) => [
      if (json is List)
        for (final item in json.whereType<Map<Object?, Object?>>())
          DeezerAlbum.fromJson(Map<String, dynamic>.from(item)),
    ],
  );

  /// `/chart/0/tracks`: the [chartTrackLimit] most played tracks on Deezer
  /// in the caller's country, cached 6 hours.
  Future<List<DeezerTrack>> chartTracks({CancelToken? cancelToken}) => _cached(
    namespace: DeezerCache.chartNamespace,
    key: '0',
    ttl: DeezerCache.chartTtl,
    fetch: () => _client.getChartTracks(
      limit: chartTrackLimit,
      cancelToken: cancelToken,
    ),
    encode: (tracks) => [for (final track in tracks) track.toJson()],
    decode: (json) => [
      if (json is List)
        for (final item in json.whereType<Map<Object?, Object?>>())
          DeezerTrack.fromJson(Map<String, dynamic>.from(item)),
    ],
  );

  Future<T> _cached<T>({
    required String namespace,
    required String key,
    required Duration ttl,
    required Future<T> Function() fetch,
    required Object? Function(T value) encode,
    required T Function(Object? json) decode,
  }) async {
    final hit = await _cache.read(namespace, key);
    if (hit != null) {
      try {
        return decode(hit.value);
      } on Object catch (error) {
        AppLogger.debug('DeezerCatalog: unreadable $namespace entry: $error');
      }
    }
    final value = await fetch();
    await _cache.write(namespace, key, encode(value), ttl: ttl);
    return value;
  }
}
