import 'package:navis/src/api/models/deezer_models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/utils/metadata_normalization.dart';

/// One artist in a "Similar Artists" or "Fans Also Like" grid.
///
/// A library artist ([libraryArtistId] set) shows its library art and opens
/// its artist page. A Deezer artist outside the library shows [imageUrl] and
/// opens the server's remote artist `ext-deezer-artist-<deezerArtistId>`,
/// whose page offers a search when the server cannot provide it; an artist
/// with neither id opens search.
class SimilarArtistEntry {
  const new({
    required this.name,
    this.libraryArtistId,
    this.deezerArtistId,
    this.coverArt,
    this.imageUrl,
  });

  final String name;
  final String? libraryArtistId;

  /// The Deezer id of an artist outside the library.
  final int? deezerArtistId;

  /// The library cover-art id.
  final String? coverArt;

  /// A photo outside the server (Deezer), for artists not in the library.
  final String? imageUrl;

  bool get isInLibrary => libraryArtistId != null;
}

/// Deezer's related artists as "Fans Also Like" entries: artists in the
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
          deezerArtistId: artist.id > 0 ? artist.id : null,
          imageUrl: artist.pictureXl ?? artist.pictureBig,
        ),
      );
    }
  }
  return <SimilarArtistEntry>[...inLibrary, ...elsewhere];
}
