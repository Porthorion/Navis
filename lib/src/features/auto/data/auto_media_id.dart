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
  static const String library = 'root/library';
  static const String instantRadio = 'root/instant_radio';
  static const String instantMix = 'root/instant_mix';

  // Quick actions and sub-categories under "Liked".
  static const String shuffleLiked = 'liked/shuffle';
  static const String likedSongs = 'liked/songs';
  static const String likedAlbums = 'liked/albums';

  // Quick actions and sub-categories under "Recent" and "Library".
  static const String resumeQueue = 'recent/resume';
  static const String downloads = 'library/downloads';
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

/// Browse container that supplied a playable song leaf.
enum AutoMediaContextType { album, playlist, downloads, liked, recent }

/// A parsed representation of a browse-tree media ID.
final class ParsedMediaId {
  const new({
    required this.type,
    this.entityId,
    this.contextType,
    this.contextId,
  });

  final AutoMediaIdType type;

  /// The entity ID (artist, album, playlist, or song ID).  Null for root and
  /// root-category nodes.
  final String? entityId;

  /// Collection whose browse view supplied this song.
  final AutoMediaContextType? contextType;

  /// Opaque server ID for [contextType].
  final String? contextId;
}

/// Codec for Android Auto media IDs.
abstract final class AutoMediaId {
  static final RegExp _invalidPercentEncoding = RegExp('%(?![0-9A-Fa-f]{2})');

  // ── Encoding ──────────────────────────────────────────────────────────────

  static String artist(String artistId) => 'artist/$artistId';
  static String album(String albumId) => 'album/$albumId';
  static String playlist(String playlistId) => 'playlist/$playlistId';
  static String song(
    String songId, {
    AutoMediaContextType? contextType,
    String? contextId,
  }) {
    if (contextType == null || contextId == null || contextId.isEmpty) {
      return 'song/$songId';
    }
    return 'song/$songId'
        '?context=${contextType.name}'
        '&contextId=${Uri.encodeQueryComponent(contextId)}';
  }

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

    // Entity prefixes. Song leaves may append browse-container context so a
    // collection selection can retain its order through playFromMediaId.
    final queryIndex = mediaId.indexOf('?');
    final path = queryIndex < 0 ? mediaId : mediaId.substring(0, queryIndex);
    final slashIndex = path.indexOf('/');
    if (slashIndex < 1 || slashIndex == path.length - 1) return null;

    final prefix = path.substring(0, slashIndex);
    final id = path.substring(slashIndex + 1);
    if (id.isEmpty) return null;
    final context = prefix == 'song' && queryIndex >= 0
        ? _parseSongContext(mediaId.substring(queryIndex + 1))
        : null;

    return switch (prefix) {
      'artist' => ParsedMediaId(type: AutoMediaIdType.artist, entityId: id),
      'album' => ParsedMediaId(type: AutoMediaIdType.album, entityId: id),
      'playlist' => ParsedMediaId(type: AutoMediaIdType.playlist, entityId: id),
      'song' => ParsedMediaId(
        type: AutoMediaIdType.song,
        entityId: id,
        contextType: context?.type,
        contextId: context?.id,
      ),
      _ => null,
    };
  }

  /// Resolves a media ID that should point at a song.
  ///
  /// Android Auto browse leaves use `song/<id>`, while platform queue and
  /// metadata callbacks can hand back the raw queue item ID. Navis queue items
  /// intentionally use raw Subsonic song IDs, so playback callbacks must
  /// accept both forms without rewriting persisted queue data.
  static String? songIdFrom(String mediaId) {
    final trimmed = mediaId.trim();
    if (trimmed.isEmpty) return null;

    final parsed = parse(trimmed);
    if (parsed != null) {
      return parsed.type == AutoMediaIdType.song ? parsed.entityId : null;
    }

    return trimmed;
  }

  static const Set<String> _rootCategories = {
    AutoMediaRoot.playlists,
    AutoMediaRoot.artists,
    AutoMediaRoot.albums,
    AutoMediaRoot.liked,
    AutoMediaRoot.recent,
    AutoMediaRoot.library,
    AutoMediaRoot.instantRadio,
    AutoMediaRoot.instantMix,
    AutoMediaRoot.shuffleLiked,
    AutoMediaRoot.resumeQueue,
    AutoMediaRoot.downloads,
  };

  static ({AutoMediaContextType type, String id})? _parseSongContext(
    String query,
  ) {
    if (_invalidPercentEncoding.hasMatch(query)) {
      return null;
    }
    final Map<String, String> parameters;
    try {
      parameters = Uri.splitQueryString(query);
    } on FormatException {
      return null;
    }
    final type = switch (parameters['context']) {
      'album' => AutoMediaContextType.album,
      'playlist' => AutoMediaContextType.playlist,
      'downloads' => AutoMediaContextType.downloads,
      'liked' => AutoMediaContextType.liked,
      'recent' => AutoMediaContextType.recent,
      _ => null,
    };
    final id = parameters['contextId']?.trim();
    if (type == null || id == null || id.isEmpty) {
      return null;
    }
    return (type: type, id: id);
  }
}
