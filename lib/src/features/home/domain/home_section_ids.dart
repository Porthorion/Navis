/// Stable section IDs used by the configurable home screen ordering.
library;

class HomeSectionIds {
  new _();

  static const String recentlyLikedAlbums = 'recently_liked_albums';
  static const String likedTracks = 'liked_tracks';
  static const String recentlyAdded = 'recently_added';
  static const String recentlyPlayed = 'recently_played';
  static const String randomAlbums = 'random_albums';
  static const String mostPlayed = 'most_played';
  static const String recentlyPlayedTracks = 'recently_played_tracks';
  static const String frequentAlbums = 'frequent_albums';
  static const String quickActions = 'quick_actions';

  static const List<String> defaultOrder = <String>[
    randomAlbums,
    recentlyLikedAlbums,
    likedTracks,
    recentlyAdded,
    recentlyPlayed,
    mostPlayed,
    recentlyPlayedTracks,
    frequentAlbums,
  ];

  static const List<String> defaultHidden = <String>[
    recentlyPlayedTracks,
    frequentAlbums,
  ];
}
