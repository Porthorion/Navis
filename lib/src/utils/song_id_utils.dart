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
