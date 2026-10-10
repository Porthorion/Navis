import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/utils/catalog_source.dart';

/// Detail responses can replace membership only after validating the whole set.
/// A missing count is supported; an explicit count must match unique tracks.
void validateAlbumSnapshot(
  Album album, {
  required String requestedId,
  bool requireCanonical = false,
  bool allowExternalReferences = false,
}) {
  if (album.id != requestedId || album.id.trim().isEmpty) {
    throw const SubsonicIncompleteResponseException(
      'Album detail identity does not match the request.',
      isConflictingSnapshot: true,
    );
  }
  final external = isExternalCatalogSource(
    id: album.id,
    apiIsExternal: album.isExternal,
  );
  if (requireCanonical && external) {
    throw const SubsonicIncompleteResponseException(
      'External album detail cannot replace a canonical catalog album.',
      isConflictingSnapshot: true,
    );
  }
  final ids = <String>{};
  for (final song in album.songs) {
    final externalReference =
        allowExternalReferences && song.isExternal == true;
    if (song.id.trim().isEmpty ||
        !ids.add(song.id) ||
        (!externalReference &&
            song.albumId?.isNotEmpty == true &&
            song.albumId != requestedId)) {
      throw const SubsonicIncompleteResponseException(
        'Album detail has invalid track membership.',
        isConflictingSnapshot: true,
      );
    }
    if (!external &&
        !externalReference &&
        isExternalCatalogSource(id: song.id, apiIsExternal: song.isExternal)) {
      throw const SubsonicIncompleteResponseException(
        'External tracks cannot replace canonical album membership.',
        isConflictingSnapshot: true,
      );
    }
  }
  if (album.songCount != null && album.songCount != album.songs.length) {
    throw const SubsonicIncompleteResponseException(
      'Album detail track count is incomplete.',
    );
  }
}

/// Validate the complete wire envelope before selecting local membership.
/// Octo-Fiesta may append explicitly external tracks under their remote album
/// IDs. Those references count toward its advertised total, not local rows.
Album canonicalAlbumSnapshot(Album album, {required String requestedId}) {
  validateAlbumSnapshot(
    album,
    requestedId: requestedId,
    requireCanonical: true,
    allowExternalReferences: true,
  );
  return album.copyWith(
    songs: album.songs
        .where(
          (song) => !isExternalCatalogSource(
            id: song.id,
            apiIsExternal: song.isExternal,
          ),
        )
        .toList(growable: false),
  );
}

void validatePlaylistSnapshot(
  Playlist playlist, {
  required String requestedId,
}) {
  if (playlist.id != requestedId ||
      playlist.id.trim().isEmpty ||
      (playlist.songCount != null &&
          playlist.songCount != playlist.entries.length) ||
      playlist.entries.any((song) => song.id.trim().isEmpty)) {
    throw const SubsonicIncompleteResponseException(
      'Playlist detail membership is incomplete.',
    );
  }
  // Repeated song identities are valid ordered playlist entries.
}
