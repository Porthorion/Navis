import 'package:dio/dio.dart';

import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/features/integrations/data/deezer_cache.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/metadata_normalization.dart';

/// Finds the Deezer artist for a library artist.
///
/// 1. A library id `ext-deezer-artist-<id>` (an artist the server imported
///    from Deezer) is used directly, with no request.
/// 2. Otherwise the normalized name is looked up in the cache
///    ([DeezerCache.artistIdNamespace]: found for 30 days, not found for 7).
/// 3. Otherwise `/search/artist` runs and only artists whose
///    [normalizeMetadata] name equals the library name's are kept. One is
///    taken as is. Between several namesakes, the one whose Deezer albums
///    share the most titles with the library's albums wins, when the caller
///    can list them; equal overlap (or no album list) goes to the most fans.
///
/// Request errors propagate and are not cached.
class DeezerArtistResolver {
  new({required this._client, required this._cache});

  /// Namesakes whose albums are compared; each costs one request.
  static const maxAlbumOverlapCandidates = 3;

  static final _libraryIdPattern = RegExp(r'^ext-deezer-artist-(\d+)$');

  final DeezerApiClient _client;
  final IntegrationJsonCache _cache;

  /// The Deezer id inside a library artist id `ext-deezer-artist-<id>`.
  static int? idFromLibraryArtistId(String artistId) {
    final match = _libraryIdPattern.firstMatch(artistId.trim().toLowerCase());
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// The Deezer artist id for the library artist [artistId] named [name], or
  /// null when Deezer has no artist of that name.
  ///
  /// [readLibraryAlbumTitles] is called only when several Deezer artists
  /// share the name.
  Future<int?> resolve({
    required String artistId,
    required String name,
    Future<Iterable<String>> Function()? readLibraryAlbumTitles,
    CancelToken? cancelToken,
  }) async {
    final direct = idFromLibraryArtistId(artistId);
    if (direct != null) return direct;

    final key = normalizeMetadata(name);
    if (key.isEmpty) return null;
    final cached = await _cache.read(DeezerCache.artistIdNamespace, key);
    if (cached != null) {
      final value = cached.value;
      return value is Map ? (value['id'] as num?)?.toInt() : null;
    }

    final namesakes = (await _client.searchArtists(
      name,
      cancelToken: cancelToken,
    )).where((artist) => normalizeMetadata(artist.name) == key).toList();
    _sortByFans(namesakes);
    final id = switch (namesakes.length) {
      0 => null,
      1 => namesakes.single.id,
      _ when readLibraryAlbumTitles == null => namesakes.first.id,
      _ => await _pickByAlbumOverlap(
        namesakes,
        readLibraryAlbumTitles,
        cancelToken,
      ),
    };
    await _cache.write(
      DeezerCache.artistIdNamespace,
      key,
      <String, Object?>{'id': id},
      ttl: id == null
          ? DeezerCache.artistNotFoundTtl
          : DeezerCache.artistFoundTtl,
    );
    return id;
  }

  Future<int> _pickByAlbumOverlap(
    List<DeezerArtist> namesakes,
    Future<Iterable<String>> Function() readLibraryAlbumTitles,
    CancelToken? cancelToken,
  ) async {
    final libraryTitles = (await readLibraryAlbumTitles())
        .map(normalizeMetadata)
        .where((title) => title.isNotEmpty)
        .toSet();
    if (libraryTitles.isEmpty) return namesakes.first.id;

    var best = namesakes.first;
    var bestOverlap = -1;
    for (final artist in namesakes.take(maxAlbumOverlapCandidates)) {
      var overlap = 0;
      try {
        final albums = await _client.getArtistAlbums(
          artist.id,
          cancelToken: cancelToken,
        );
        overlap = albums
            .map((album) => normalizeMetadata(album.title))
            .where(libraryTitles.contains)
            .toSet()
            .length;
      } on DeezerApiException catch (error) {
        AppLogger.debug('DeezerArtistResolver: albums of ${artist.id}: $error');
      }
      // Strictly greater, so equal overlap keeps the artist with more fans.
      if (overlap > bestOverlap) {
        best = artist;
        bestOverlap = overlap;
      }
    }
    return best.id;
  }

  static void _sortByFans(List<DeezerArtist> artists) {
    final order = <DeezerArtist, int>{
      for (var i = 0; i < artists.length; i++) artists[i]: i,
    };
    artists.sort((a, b) {
      final byFans = (b.fanCount ?? 0).compareTo(a.fanCount ?? 0);
      return byFans != 0 ? byFans : order[a]!.compareTo(order[b]!);
    });
  }
}
