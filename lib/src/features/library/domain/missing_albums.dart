import 'package:navis/src/api/models/deezer_models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/utils/metadata_normalization.dart';

/// Deezer record types shown as missing albums. Singles appear only in
/// Home's new releases, and compilations are left out.
const Set<String> missingAlbumRecordTypes = <String>{'album', 'ep'};

final _deezerAlbumIdPattern = RegExp(r'^ext-deezer-album-(\d+)$');

/// The Deezer id inside a library album id `ext-deezer-album-<id>`.
int? deezerIdFromLibraryAlbumId(String albumId) {
  final match = _deezerAlbumIdPattern.firstMatch(albumId.trim().toLowerCase());
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// An artist's Deezer albums and EPs that the library does not have, newest
/// first.
///
/// A Deezer album is in the library when a library album (the artist's own
/// or one it is featured on) has its id as `ext-deezer-album-<id>` or the same
/// [normalizeMetadataKeepingEdition] title. That key drops remaster and
/// deluxe-style packaging words but keeps every other qualifier, so
/// "Ambitions (Japanese Version)" is still missing when the library has only
/// "Ambitions". Deezer's own duplicates of one edition (explicit and clean
/// releases) appear once.
///
/// Callers show nothing when the server has remote albums for the artist:
/// its remote catalogue is the better source.
List<DeezerAlbum> missingDeezerAlbums({
  required List<DeezerAlbum> deezerAlbums,
  required Iterable<AlbumsTableData> libraryAlbums,
}) {
  final libraryDeezerIds = <int>{};
  final libraryTitles = <String>{};
  for (final album in libraryAlbums) {
    final deezerId = deezerIdFromLibraryAlbumId(album.id);
    if (deezerId != null) libraryDeezerIds.add(deezerId);
    final title = normalizeMetadataKeepingEdition(album.name);
    if (title.isNotEmpty) libraryTitles.add(title);
  }

  final candidates = deezerAlbums
      .where(
        (album) =>
            missingAlbumRecordTypes.contains(album.recordType?.toLowerCase()),
      )
      .toList(growable: false);
  final order = <DeezerAlbum, int>{
    for (var i = 0; i < candidates.length; i++) candidates[i]: i,
  };
  final newestFirst = candidates.toList()
    ..sort((a, b) {
      final byDate = (b.releaseDate ?? '').compareTo(a.releaseDate ?? '');
      return byDate != 0 ? byDate : order[a]!.compareTo(order[b]!);
    });

  final seen = <String>{};
  return <DeezerAlbum>[
    for (final album in newestFirst)
      if (_titleKey(album) case final title
          when !libraryDeezerIds.contains(album.id) &&
              !libraryTitles.contains(title) &&
              seen.add(title))
        album,
  ];
}

String _titleKey(DeezerAlbum album) {
  final key = normalizeMetadataKeepingEdition(album.title);
  return key.isEmpty ? 'id:${album.id}' : key;
}
