import 'dart:convert';

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
/// 2. Otherwise the mapping is looked up in the cache
///    ([DeezerCache.artistIdNamespace]: found for 30 days, not found for 7),
///    keyed by the server account ([accountScope]), the library artist id and
///    the normalized name. Two library artists sharing a name (namesakes told
///    apart by their albums) and two accounts never share a mapping.
/// 3. Otherwise `/search/artist` runs and only artists whose
///    [normalizeMetadata] name equals the library name's are kept. One is
///    taken as is. Between several namesakes, the one whose Deezer albums
///    share the most titles with the library's albums wins, when the caller
///    can list them; equal overlap (or no album list) goes to the most fans.
/// 4. When no name is equal, artists whose names [artistNamesMatchLoosely]
///    ("The Black Eyed Peas" and Deezer's "Black Eyed Peas", "Simon and
///    Garfunkel" and "Simon & Garfunkel") are only candidates: one is taken
///    only when its Deezer albums share at least one title with the library
///    artist's (most shared, then most fans). Without library album titles,
///    no loose match is accepted, so a different artist's photo, songs and
///    missing albums are never bound to the page on a name alone.
///
/// A failed search propagates and is not cached. A failed album lookup
/// (anything but a cancellation, which propagates) makes the resolution
/// inconclusive: no further albums are fetched, nothing is cached, and the
/// call answers without the album evidence (no loose match; the namesake
/// with the most fans), so the next call asks again. Only a decision whose
/// every lookup answered is cached, "not on Deezer" included. Concurrent
/// calls for the same library artist and name share one resolution.
class DeezerArtistResolver {
  new({required this._client, required this._cache, this.accountScope = ''});

  /// Namesakes whose albums are compared; each costs one request.
  static const maxAlbumOverlapCandidates = 3;

  static final _libraryIdPattern = RegExp(r'^ext-deezer-artist-(\d+)$');

  /// Version of the cached mappings. Version 2 tried loose names before
  /// caching "not on Deezer".
  static const _cacheVersion = 2;

  /// A non-credential identity of the signed-in server account; library
  /// artist ids are only unique within one server.
  final String accountScope;

  final DeezerApiClient _client;
  final IntegrationJsonCache _cache;

  /// Resolutions running now, by account, library artist id and normalized
  /// name.
  final Map<String, Future<DeezerArtistResolution>> _inFlight =
      <String, Future<DeezerArtistResolution>>{};

  /// The Deezer id inside a library artist id `ext-deezer-artist-<id>`.
  static int? idFromLibraryArtistId(String artistId) {
    final match = _libraryIdPattern.firstMatch(artistId.trim().toLowerCase());
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// The Deezer artist id for the library artist [artistId] named [name], or
  /// null when Deezer has no artist of that name.
  ///
  /// [readLibraryAlbumTitles] is called only when several Deezer artists
  /// share the name. A [background] resolution (Home's warm-up) yields the
  /// Deezer limiter to what the user is looking at.
  Future<int?> resolve({
    required String artistId,
    required String name,
    Future<Iterable<String>> Function()? readLibraryAlbumTitles,
    CancelToken? cancelToken,
    bool background = false,
  }) async => (await resolveWithOutcome(
    artistId: artistId,
    name: name,
    readLibraryAlbumTitles: readLibraryAlbumTitles,
    cancelToken: cancelToken,
    background: background,
  )).id;

  /// [resolve], also telling whether the answer is conclusive: false when an
  /// album lookup failed, so the answer was not cached and a null id may not
  /// mean "not on Deezer".
  Future<DeezerArtistResolution> resolveWithOutcome({
    required String artistId,
    required String name,
    Future<Iterable<String>> Function()? readLibraryAlbumTitles,
    CancelToken? cancelToken,
    bool background = false,
  }) async {
    final direct = idFromLibraryArtistId(artistId);
    if (direct != null) return (id: direct, conclusive: true);

    final key = normalizeMetadata(name);
    if (key.isEmpty) return (id: null, conclusive: true);

    // Top songs and the artist page's other Deezer sections resolve the same
    // artist at the same time; they share one resolution.
    final mappingKey = jsonEncode(<String>[accountScope, artistId.trim(), key]);
    final pending = _inFlight[mappingKey];
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
      mappingKey: mappingKey,
      nameKey: key,
      name: name,
      readLibraryAlbumTitles: readLibraryAlbumTitles,
      cancelToken: cancelToken,
      background: background,
    );
    _inFlight[mappingKey] = resolution;
    try {
      return await resolution;
    } finally {
      _inFlight.removeWhere((_, pending) => identical(pending, resolution));
    }
  }

  Future<DeezerArtistResolution> _resolveByName({
    required String mappingKey,
    required String nameKey,
    required String name,
    required Future<Iterable<String>> Function()? readLibraryAlbumTitles,
    required CancelToken? cancelToken,
    required bool background,
  }) async {
    final cached = await _cache.read(DeezerCache.artistIdNamespace, mappingKey);
    final value = cached?.value;
    if (value is Map) {
      final id = (value['id'] as num?)?.toInt();
      // "Not on Deezer" from before loose names were tried is asked again.
      if (id != null || value['v'] == _cacheVersion) {
        return (id: id, conclusive: true);
      }
    }

    final found = await _client.searchArtists(
      name,
      cancelToken: cancelToken,
      background: background,
    );
    final namesakes = found
        .where((artist) => normalizeMetadata(artist.name) == nameKey)
        .toList();
    _sortByFans(namesakes);
    final (:id, :conclusive) = switch (namesakes.length) {
      0 => await _pickLooseMatch(
        found
            .where((artist) => artistNamesMatchLoosely(name, artist.name))
            .toList(),
        readLibraryAlbumTitles,
        cancelToken,
        background,
      ),
      1 => (id: namesakes.single.id, conclusive: true),
      _ when readLibraryAlbumTitles == null => (
        id: namesakes.first.id,
        conclusive: true,
      ),
      _ => await _pickByAlbumOverlap(
        namesakes,
        readLibraryAlbumTitles,
        cancelToken,
        background,
      ),
    };
    // Asked again next time rather than remembered for days.
    if (!conclusive) return (id: id, conclusive: false);
    await _cache.write(
      DeezerCache.artistIdNamespace,
      mappingKey,
      <String, Object?>{'id': id, 'v': _cacheVersion},
      ttl: id == null
          ? DeezerCache.artistNotFoundTtl
          : DeezerCache.artistFoundTtl,
    );
    return (id: id, conclusive: true);
  }

  /// Of [namesakes] (sorted by fans), the one sharing the most album titles
  /// with the library artist; the first when an album lookup failed.
  Future<DeezerArtistResolution> _pickByAlbumOverlap(
    List<DeezerArtist> namesakes,
    Future<Iterable<String>> Function() readLibraryAlbumTitles,
    CancelToken? cancelToken,
    bool background,
  ) async {
    final libraryTitles = await _libraryTitleKeys(readLibraryAlbumTitles);
    if (libraryTitles.isEmpty) {
      return (id: namesakes.first.id, conclusive: true);
    }
    final (:best, :conclusive) = await _mostSharedAlbums(
      namesakes,
      libraryTitles,
      cancelToken,
      background: background,
    );
    return (id: best?.id ?? namesakes.first.id, conclusive: conclusive);
  }

  /// Of [candidates] (names equal only loosely), the one sharing the most
  /// album titles with the library artist, or null when none shares any, the
  /// library's titles are unknown or an album lookup failed.
  Future<DeezerArtistResolution> _pickLooseMatch(
    List<DeezerArtist> candidates,
    Future<Iterable<String>> Function()? readLibraryAlbumTitles,
    CancelToken? cancelToken,
    bool background,
  ) async {
    if (candidates.isEmpty || readLibraryAlbumTitles == null) {
      return (id: null, conclusive: true);
    }
    final libraryTitles = await _libraryTitleKeys(readLibraryAlbumTitles);
    if (libraryTitles.isEmpty) return (id: null, conclusive: true);
    _sortByFans(candidates);
    final (:best, :conclusive) = await _mostSharedAlbums(
      candidates,
      libraryTitles,
      cancelToken,
      minimumOverlap: 1,
      background: background,
    );
    return (id: best?.id, conclusive: conclusive);
  }

  static Future<Set<String>> _libraryTitleKeys(
    Future<Iterable<String>> Function() readLibraryAlbumTitles,
  ) async => (await readLibraryAlbumTitles())
      .map(normalizeMetadata)
      .where((title) => title.isNotEmpty)
      .toSet();

  /// Of the first [maxAlbumOverlapCandidates] of [artists] (sorted by fans),
  /// the one whose Deezer albums share the most titles with [libraryTitles],
  /// at least [minimumOverlap]; equal overlap keeps the one with more fans.
  ///
  /// When an album lookup fails the comparison stops there, sparing the
  /// quota requests whose answers would not be used, and the result is
  /// `(best: null, conclusive: false)`. A cancellation propagates.
  Future<({DeezerArtist? best, bool conclusive})> _mostSharedAlbums(
    List<DeezerArtist> artists,
    Set<String> libraryTitles,
    CancelToken? cancelToken, {
    int minimumOverlap = 0,
    required bool background,
  }) async {
    DeezerArtist? best;
    var bestOverlap = minimumOverlap - 1;
    for (final artist in artists.take(maxAlbumOverlapCandidates)) {
      final List<DeezerAlbum> albums;
      try {
        albums = await _client.getArtistAlbums(
          artist.id,
          cancelToken: cancelToken,
          background: background,
        );
      } on Exception catch (error) {
        if ((error is DioException && CancelToken.isCancel(error)) ||
            (cancelToken?.isCancelled ?? false)) {
          rethrow;
        }
        AppLogger.debug(
          'DeezerArtistResolver: albums of ${artist.id} failed, not caching '
          'the resolution: $error',
        );
        return (best: null, conclusive: false);
      }
      final overlap = albums
          .map((album) => normalizeMetadata(album.title))
          .where(libraryTitles.contains)
          .toSet()
          .length;
      // Strictly greater, so equal overlap keeps the artist with more fans.
      if (overlap > bestOverlap) {
        best = artist;
        bestOverlap = overlap;
      }
    }
    return (best: best, conclusive: true);
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

/// A Deezer artist id (null: none found), and whether every lookup the
/// decision depends on answered; an inconclusive one is not cached.
typedef DeezerArtistResolution = ({int? id, bool conclusive});

/// Leading articles one name may have and the other lack.
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

/// A name for loose comparison: its leading article, if any, and the rest
/// without spaces. "&" reads as "and". The article stays part of the rest
/// when nothing but an article would remain, so "The The" is never "The".
({String? article, String rest}) _looseName(String name) {
  final words = normalizeMetadata(name.replaceAll(_ampersand, ' and '))
      .split(' ')
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.length > 1 &&
      _leadingArticles.contains(words.first) &&
      !(words.length == 2 && _leadingArticles.contains(words[1]))) {
    return (article: words.first, rest: words.skip(1).join());
  }
  return (article: null, rest: words.join());
}

/// Whether [libraryName] and [deezerName] may name the same artist although
/// their [normalizeMetadata] forms differ, for resolution only (never shown).
///
/// They may differ in one leading article present on one side only ("The",
/// "A", "An", "Los", "Las", "Le", "La", "Les", "Die", "Der"), in "&" against
/// "and", and in spacing and punctuation: "The Black Eyed Peas" and "Black
/// Eyed Peas", "Simon & Garfunkel" and "Simon and Garfunkel", "AC/DC" and
/// "ACDC". Two different articles ("A Band", "The Band") never match. A
/// loose match is only a candidate; the resolver also asks for shared albums.
bool artistNamesMatchLoosely(String libraryName, String deezerName) {
  final library = _looseName(libraryName);
  final deezer = _looseName(deezerName);
  if (library.rest.isEmpty || library.rest != deezer.rest) return false;
  return library.article == null ||
      deezer.article == null ||
      library.article == deezer.article;
}
