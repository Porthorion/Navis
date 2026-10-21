/// Stable section IDs used by the configurable home screen ordering.
library;

class HomeSectionIds {
  new _();

  static const String recentlyLikedAlbums = 'recently_liked_albums';
  static const String likedTracks = 'liked_tracks';
  static const String recentlyAdded = 'recently_added';

  /// A plain random-albums row (opt-in). Not [randomAlbums], the legacy id of
  /// You Might Like.
  static const String randomAlbumList = 'random_album_list';
  static const String recentlyPlayed = 'recently_played';
  static const String randomAlbums = 'random_albums';
  static const String mostPlayed = 'most_played';
  static const String recentlyPlayedTracks = 'recently_played_tracks';
  static const String frequentAlbums = 'frequent_albums';
  static const String quickActions = 'quick_actions';

  /// Recent Deezer releases by the user's artists; hides itself until it
  /// has some.
  static const String newReleases = 'new_releases';

  static const List<String> defaultOrder = <String>[
    randomAlbums,
    newReleases,
    recentlyLikedAlbums,
    likedTracks,
    recentlyAdded,
    randomAlbumList,
    recentlyPlayed,
    mostPlayed,
    recentlyPlayedTracks,
    frequentAlbums,
  ];

  static const List<String> defaultHidden = <String>[
    randomAlbumList,
    recentlyPlayedTracks,
    frequentAlbums,
  ];

  /// The ids that existed before Home gained sections in 1.5.0. Every user
  /// with a saved hidden list has seen them, so that list alone decides
  /// whether they show.
  static const Set<String> _legacyIds = <String>{
    recentlyLikedAlbums,
    likedTracks,
    recentlyAdded,
    recentlyPlayed,
    randomAlbums,
    mostPlayed,
    recentlyPlayedTracks,
    frequentAlbums,
    quickActions,
  };

  /// The Home order for the saved [persisted] order (null: never saved).
  ///
  /// Saved ids keep their order; unknown and repeated ids are dropped. A
  /// default section the saved order lacks, such as one added in a later
  /// version, goes right after the nearest section before it in [defaults]
  /// that is present, or first when there is none.
  static List<String> resolveOrder(
    List<String>? persisted, {
    List<String> defaults = defaultOrder,
  }) {
    if (persisted == null) return List<String>.unmodifiable(defaults);
    final known = defaults.toSet();
    final order = <String>[];
    for (final id in persisted) {
      if (known.contains(id) && !order.contains(id)) order.add(id);
    }
    for (var index = 0; index < defaults.length; index++) {
      final id = defaults[index];
      if (order.contains(id)) continue;
      var insertAt = 0;
      for (var previous = index - 1; previous >= 0; previous--) {
        final at = order.indexOf(defaults[previous]);
        if (at >= 0) {
          insertAt = at + 1;
          break;
        }
      }
      order.insert(insertAt, id);
    }
    return List<String>.unmodifiable(order);
  }

  /// The hidden Home sections for the saved [persistedHidden] list (null:
  /// never saved, so [hiddenByDefault]) and the saved [persistedOrder].
  ///
  /// The saved list decides every section the user has seen. A section that
  /// is hidden by default and that the user has never seen (added later, and
  /// in neither saved list) stays hidden. Unknown ids are dropped.
  static List<String> resolveHidden(
    List<String>? persistedHidden, {
    List<String>? persistedOrder,
    List<String> defaults = defaultOrder,
    List<String> hiddenByDefault = defaultHidden,
  }) {
    if (persistedHidden == null) {
      return List<String>.unmodifiable(hiddenByDefault);
    }
    final known = defaults.toSet();
    final seen = <String>{
      ..._legacyIds,
      ...?persistedOrder,
      ...persistedHidden,
    };
    return List<String>.unmodifiable(<String>{
      ...persistedHidden.where(known.contains),
      ...hiddenByDefault.where((id) => !seen.contains(id)),
    });
  }
}
