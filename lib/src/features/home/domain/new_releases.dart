import 'package:navis/src/api/models/deezer_models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/missing_albums.dart';
import 'package:navis/src/utils/metadata_normalization.dart';

/// How far back Home's New releases look.
const Duration kNewReleasesWindow = Duration(days: 30);

/// The most releases Home's New releases shows.
const int kNewReleasesLimit = 12;

/// A recent Deezer release by one of the user's artists.
class HomeNewRelease {
  const new({
    required this.album,
    required this.releasedOn,
    required this.artistId,
    required this.artistName,
    this.libraryAlbumId,
  });

  final DeezerAlbum album;

  /// The release day, from Deezer's `release_date`.
  final DateTime releasedOn;

  /// The library artist it was found for.
  final String artistId;
  final String artistName;

  /// The library album that is this release, when the library has it.
  final String? libraryAlbumId;
}

/// One library artist's Deezer releases, as Home's New releases reads them.
typedef ArtistReleases = ({
  ArtistsTableData artist,
  List<DeezerAlbum> releases,
  List<AlbumsTableData> libraryAlbums,
});

/// The day of Deezer's `YYYY-MM-DD` [releaseDate], or null when it is
/// missing or malformed.
DateTime? parseDeezerReleaseDate(String? releaseDate) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$')
      .firstMatch(releaseDate?.trim() ?? '');
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (year <= 0 || month < 1 || month > 12 || day < 1 || day > 31) {
    return null;
  }
  final date = DateTime(year, month, day);
  // DateTime rolls 2026-02-31 over into March; such a date is malformed.
  return date.month == month ? date : null;
}

/// The library album that is the Deezer [album], among [libraryAlbums]: the
/// one stored as `ext-deezer-album-<id>`, else one with the same
/// [normalizeMetadataKeepingEdition] title, so "Wonder (Japanese Version)"
/// never opens "Wonder".
String? libraryAlbumIdForRelease(
  DeezerAlbum album,
  Iterable<AlbumsTableData> libraryAlbums,
) {
  final title = normalizeMetadataKeepingEdition(album.title);
  String? byTitle;
  for (final libraryAlbum in libraryAlbums) {
    if (deezerIdFromLibraryAlbumId(libraryAlbum.id) == album.id) {
      return libraryAlbum.id;
    }
    if (byTitle == null &&
        title.isNotEmpty &&
        normalizeMetadataKeepingEdition(libraryAlbum.name) == title) {
      byTitle = libraryAlbum.id;
    }
  }
  return byTitle;
}

/// Home's New releases from each artist's [ArtistReleases], in the order the
/// artists rank: releases from the [kNewReleasesWindow] before [today]
/// (inclusive; announced future dates excluded), newest first, an artist's
/// higher rank deciding a tie, at most [limit]. Each Deezer album appears
/// once, and so does each edition of an artist's release (Deezer lists
/// explicit and clean releases separately).
List<HomeNewRelease> selectNewReleases(
  List<ArtistReleases> byArtist, {
  required DateTime today,
  int limit = kNewReleasesLimit,
}) {
  final day = DateTime(today.year, today.month, today.day);
  // Calendar days, so a daylight-saving change cannot move the boundary.
  final earliest = DateTime(
    day.year,
    day.month,
    day.day - kNewReleasesWindow.inDays,
  );
  final seenIds = <int>{};
  final seenTitles = <String>{};
  final found = <({HomeNewRelease release, int rank})>[];
  for (var rank = 0; rank < byArtist.length; rank++) {
    final entry = byArtist[rank];
    for (final album in entry.releases) {
      final releasedOn = parseDeezerReleaseDate(album.releaseDate);
      if (releasedOn == null ||
          releasedOn.isAfter(day) ||
          releasedOn.isBefore(earliest) ||
          !seenIds.add(album.id) ||
          !seenTitles.add(
            '${entry.artist.id}\u001f'
            '${normalizeMetadataKeepingEdition(album.title)}',
          )) {
        continue;
      }
      found.add((
        release: HomeNewRelease(
          album: album,
          releasedOn: releasedOn,
          artistId: entry.artist.id,
          artistName: entry.artist.name,
          libraryAlbumId: libraryAlbumIdForRelease(album, entry.libraryAlbums),
        ),
        rank: rank,
      ));
    }
  }
  found.sort((a, b) {
    final byDate = b.release.releasedOn.compareTo(a.release.releasedOn);
    return byDate != 0 ? byDate : a.rank.compareTo(b.rank);
  });
  return List<HomeNewRelease>.unmodifiable(
    found.take(limit).map((entry) => entry.release),
  );
}
