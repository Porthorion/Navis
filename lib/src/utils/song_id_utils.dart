import 'package:navis/src/utils/catalog_source.dart';

/// Returns true when [id] refers to a song that can be addressed via the
/// Subsonic API (star, unstar, setRating, getInstantMix seed, etc.).
///
/// External / plugin-injected songs carry prefixes like `ext-` or `remote-`
/// that make them invisible to the server.  Any interaction that requires the
/// server to look up the ID by value (liking, rating, downloading, legacy
/// Instant Mix) will fail for these IDs.
bool isServerAddressableSongId(String id) {
  final normalized = id.trim().toLowerCase();
  if (normalized.isEmpty) return false;
  if (normalized.startsWith('ext-') || normalized.startsWith('remote-')) {
    return false;
  }
  return true;
}

/// Whether a song is a remote catalogue copy that can never be liked: its id
/// is not server-addressable, or the catalogue flags it external ([isExternal]
/// when known, else the id prefix). Streaming and downloads keep using
/// [isServerAddressableSongId].
bool isRemoteSong({required String id, bool? isExternal}) =>
    !isServerAddressableSongId(id) ||
    isExternalCatalogSource(id: id, apiIsExternal: isExternal);
