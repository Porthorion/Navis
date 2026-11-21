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

  /// Deezer artist id → the first few `/artist/{id}/albums`, for New
  /// releases on Home.
  static const artistRecentAlbumsNamespace = 'deezer.artist-recent-albums';

  /// Deezer track id → `/track/{id}` (bpm, release date, explicit flag).
  static const trackNamespace = 'deezer.track';

  /// Deezer artist id → the raw `/artist/{id}/top?limit=5`, Deezer's order.
  static const artistTopFiveNamespace = 'deezer.artist-top5';

  /// `/chart/0/tracks`, for Trending on Home.
  static const chartNamespace = 'deezer.chart';

  static const artistFoundTtl = Duration(days: 30);
  static const artistNotFoundTtl = Duration(days: 7);
  static const artistDetailsTtl = Duration(days: 7);
  static const relatedArtistsTtl = Duration(days: 7);
  static const albumsTtl = Duration(hours: 24);

  static const trackTtl = Duration(days: 30);
  static const topFiveTtl = Duration(hours: 24);
  static const trackSearchTtl = Duration(hours: 24);
  static const chartTtl = Duration(hours: 6);

  /// Search results change little; a query typed back and forth is reused
  /// (in memory only, by `DeezerCatalog`).
  static const searchTtl = Duration(minutes: 10);
}
