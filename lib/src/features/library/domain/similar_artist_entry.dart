import 'package:navis/src/api/models/deezer_models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/utils/metadata_normalization.dart';

/// One artist in a "Similar Artists" or "Fans also like" grid.
///
/// A library artist ([libraryArtistId] set) shows its library art and opens
/// its artist page. Any other artist shows [imageUrl] and opens search, so a
/// tap never lands on an "Artist Not Found" page.
class SimilarArtistEntry {
  const new({
    required this.name,
    this.libraryArtistId,
    this.coverArt,
    this.imageUrl,
  });

  final String name;
  final String? libraryArtistId;

  /// The library cover-art id.
  final String? coverArt;

  /// A photo outside the server (Deezer), for artists not in the library.
  final String? imageUrl;

  bool get isInLibrary => libraryArtistId != null;
}

/// Deezer's related artists as "Fans also like" entries: artists in the
/// library first, then the rest, each group in Deezer's order.
///
/// [libraryByName] maps `normalizeMetadata` names to library artists (see
/// `LibraryDao.findArtistsByNormalizedNames`). The artist of the page and
/// repeated names are left out.
List<SimilarArtistEntry> fansAlsoLikeEntries({
  required List<DeezerArtist> related,
  required Map<String, ArtistsTableData> libraryByName,
  required String currentArtistId,
  required String currentArtistName,
}) {
  final seen = <String>{normalizeMetadata(currentArtistName)};
  final inLibrary = <SimilarArtistEntry>[];
  final elsewhere = <SimilarArtistEntry>[];
  for (final artist in related) {
    final key = normalizeMetadata(artist.name);
    if (key.isEmpty || !seen.add(key)) continue;
    final match = libraryByName[key];
    if (match != null) {
      if (match.id == currentArtistId) continue;
      inLibrary.add(
        SimilarArtistEntry(
          name: match.name,
          libraryArtistId: match.id,
          coverArt: match.coverArt,
        ),
      );
    } else {
      elsewhere.add(
        SimilarArtistEntry(
          name: artist.name,
          imageUrl: artist.pictureXl ?? artist.pictureBig,
        ),
      );
    }
  }
  return <SimilarArtistEntry>[...inLibrary, ...elsewhere];
}
