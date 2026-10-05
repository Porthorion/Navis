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
///    [normalizeMetadata] name equals the library name's are kept. When none
///    does, artists whose [artistNameResolutionKey] equals the library
///    name's are kept instead ("The Black Eyed Peas" is Deezer's "Black Eyed
///    Peas", "Simon and Garfunkel" its "Simon & Garfunkel"). One is taken as
///    is. Between several namesakes, the one whose Deezer albums share the
///    most titles with the library's albums wins, when the caller can list
///    them; equal overlap (or no album list) goes to the most fans.
///
/// Request errors propagate and are not cached. Concurrent calls for the same
/// library artist and name share one resolution.
class DeezerArtistResolver {
  new({required this._client, required this._cache});

  /// Namesakes whose albums are compared; each costs one request.
  static const maxAlbumOverlapCandidates = 3;

  static final _libraryIdPattern = RegExp(r'^ext-deezer-artist-(\d+)$');

  /// Version of the cached mappings. Version 2 tried loose names before
  /// caching "not on Deezer".
  static const _cacheVersion = 2;

  final DeezerApiClient _client;
  final IntegrationJsonCache _cache;

  /// Resolutions running now, by library artist id and normalized name.
  final Map<String, Future<int?>> _inFlight = <String, Future<int?>>{};

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

    // Top songs and the artist page's other Deezer sections resolve the same
    // artist at the same time; they share one resolution.
    final flightKey = '${artistId.trim()}\u0000$key';
    final pending = _inFlight[flightKey];
    if (pending != null) {
      try {
        return await pending;
      } on DioException catch (error) {
        // The caller that started it left; resolve again for this one.
        final cancelledHere = cancelToken?.isCancelled ?? false;
        if (!CancelToken.isCancel(error) || cancelledHere) rethrow;
      }
    }
    final resolution = _resolveByName(
      key: key,
      name: name,
      readLibraryAlbumTitles: readLibraryAlbumTitles,
      cancelToken: cancelToken,
    );
    _inFlight[flightKey] = resolution;
    try {
      return await resolution;
    } finally {
      _inFlight.removeWhere((_, pending) => identical(pending, resolution));
    }
  }

  Future<int?> _resolveByName({
    required String key,
    required String name,
    required Future<Iterable<String>> Function()? readLibraryAlbumTitles,
    required CancelToken? cancelToken,
  }) async {
    final cached = await _cache.read(DeezerCache.artistIdNamespace, key);
    final value = cached?.value;
    if (value is Map) {
      final id = (value['id'] as num?)?.toInt();
      // "Not on Deezer" from before loose names were tried is asked again.
      if (id != null || value['v'] == _cacheVersion) return id;
    }

    final found = await _client.searchArtists(name, cancelToken: cancelToken);
    var namesakes = found
        .where((artist) => normalizeMetadata(artist.name) == key)
        .toList();
    if (namesakes.isEmpty) {
      final loose = artistNameResolutionKey(name);
      namesakes = found
          .where((artist) => artistNameResolutionKey(artist.name) == loose)
          .toList();
    }
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
      <String, Object?>{'id': id, 'v': _cacheVersion},
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

/// Leading articles ignored when names are compared for resolution.
const Set<String> _leadingArticles = {
  'the',
  'a',
  'an',
  'los',
  'las',
  'le',
  'la',
  'les',
  'die',
  'der',
};

final RegExp _ampersand = RegExp(r'[&\uFF06]');

/// A looser key than [normalizeMetadata] for telling whether a Deezer artist
/// is the library's, used only to resolve the artist and never shown.
///
/// "&" reads as "and", one leading article is dropped ("The", "A", "An",
/// "Los", "Las", "Le", "La", "Les", "Die", "Der") and spaces are removed, so
/// "The Black Eyed Peas", "Black Eyed Peas" and "Black-Eyed Peas" agree, as
/// do "Simon & Garfunkel" and "Simon and Garfunkel", and "AC/DC" and "ACDC".
/// The article stays when nothing but an article would remain, so "The The"
/// is never "The".
String artistNameResolutionKey(String name) {
  final words = normalizeMetadata(name.replaceAll(_ampersand, ' and '))
      .split(' ')
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.length > 1 &&
      _leadingArticles.contains(words.first) &&
      !(words.length == 2 && _leadingArticles.contains(words[1]))) {
    words.removeAt(0);
  }
  return words.join();
}
