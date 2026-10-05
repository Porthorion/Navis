/// Cache namespaces and lifetimes for Deezer data in `IntegrationJsonCache`.
///
/// One place, so every Deezer feature keeps the same data for the same time.
abstract final class DeezerCache {
  /// Normalized artist name → Deezer artist id (or "not on Deezer").
  static const artistIdNamespace = 'deezer.artist-id';

  /// Deezer artist id → the artist's ranked top tracks.
  static const artistTopTracksNamespace = 'deezer.artist-top-tracks';

  /// Deezer artist id → `/artist/{id}` (photo and fan count).
  static const artistDetailsNamespace = 'deezer.artist-details';

  /// Deezer artist id → `/artist/{id}/related`.
  static const relatedArtistsNamespace = 'deezer.artist-related';

  /// Deezer artist id → `/artist/{id}/albums`.
  static const artistAlbumsNamespace = 'deezer.artist-albums';

  /// Deezer album id → `/album/{id}` (track count).
  static const albumNamespace = 'deezer.album';

  static const artistFoundTtl = Duration(days: 30);
  static const artistNotFoundTtl = Duration(days: 7);
  static const artistDetailsTtl = Duration(days: 7);
  static const relatedArtistsTtl = Duration(days: 7);
  static const albumsTtl = Duration(hours: 24);

  /// One release's details; they barely change once it is out.
  static const albumTtl = Duration(days: 7);
  static const trackSearchTtl = Duration(hours: 24);
  static const chartTtl = Duration(hours: 6);
}
