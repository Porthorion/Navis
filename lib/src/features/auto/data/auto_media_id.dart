/// Media ID encoding/decoding for Android Auto browse tree.
///
/// All browse-tree nodes use a URI-like string that encodes the node type and
/// identity so that [AutoMediaTreeService] can resolve children and playback
/// targets from a single opaque ID.
library;

/// Well-known root node IDs.
abstract final class AutoMediaRoot {
  static const String root = 'root';
  static const String playlists = 'root/playlists';
  static const String artists = 'root/artists';
  static const String albums = 'root/albums';
  static const String liked = 'root/liked';
  static const String recent = 'root/recent';
  static const String randomMix = 'root/random';

  /// Search tab — lists all songs sorted by name for manual browsing.
  static const String search = 'root/search';

  /// Secondary "More" node that groups less-frequently accessed categories.
  static const String more = 'root/more';

  // Sub-categories under "liked"
  static const String likedSongs = 'liked/songs';
  static const String likedAlbums = 'liked/albums';
}

/// Identifies the type of node a media ID represents.
enum AutoMediaIdType {
  root,
  rootCategory,
  artist,
  album,
  playlist,
  song,
  likedSubcategory,
}

/// A parsed representation of a browse-tree media ID.
final class ParsedMediaId {
  const ParsedMediaId({required this.type, this.entityId});

  final AutoMediaIdType type;

  /// The entity ID (artist, album, playlist, or song ID).  Null for root and
  /// root-category nodes.
  final String? entityId;
}

/// Codec for Android Auto media IDs.
abstract final class AutoMediaId {
  // ── Encoding ──────────────────────────────────────────────────────────────

  static String artist(String artistId) => 'artist/$artistId';
  static String album(String albumId) => 'album/$albumId';
  static String playlist(String playlistId) => 'playlist/$playlistId';
  static String song(String songId) => 'song/$songId';

  // ── Decoding ──────────────────────────────────────────────────────────────

  /// Parses a raw media ID into its structured representation.
  ///
  /// Returns `null` for malformed or unrecognised IDs.
  static ParsedMediaId? parse(String mediaId) {
    if (mediaId.isEmpty) return null;

    // Root node
    if (mediaId == AutoMediaRoot.root) {
      return const ParsedMediaId(type: AutoMediaIdType.root);
    }

    // Root-level categories
    if (_rootCategories.contains(mediaId)) {
      return const ParsedMediaId(type: AutoMediaIdType.rootCategory);
    }

    // Liked sub-categories
    if (mediaId == AutoMediaRoot.likedSongs ||
        mediaId == AutoMediaRoot.likedAlbums) {
      return const ParsedMediaId(type: AutoMediaIdType.likedSubcategory);
    }

    // Entity prefixes
    final slashIndex = mediaId.indexOf('/');
    if (slashIndex < 1 || slashIndex == mediaId.length - 1) return null;

    final prefix = mediaId.substring(0, slashIndex);
    final id = mediaId.substring(slashIndex + 1);

    return switch (prefix) {
      'artist' => ParsedMediaId(
        type: AutoMediaIdType.artist,
        entityId: id,
      ),
      'album' => ParsedMediaId(
        type: AutoMediaIdType.album,
        entityId: id,
      ),
      'playlist' => ParsedMediaId(
        type: AutoMediaIdType.playlist,
        entityId: id,
      ),
      'song' => ParsedMediaId(
        type: AutoMediaIdType.song,
        entityId: id,
      ),
      _ => null,
    };
  }

  static const Set<String> _rootCategories = {
    AutoMediaRoot.playlists,
    AutoMediaRoot.artists,
    AutoMediaRoot.albums,
    AutoMediaRoot.liked,
    AutoMediaRoot.recent,
    AutoMediaRoot.randomMix,
    AutoMediaRoot.more,
    AutoMediaRoot.search,
  };
}
