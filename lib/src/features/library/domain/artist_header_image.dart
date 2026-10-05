/// Which photos the artist page header may try, in order.
library;

/// The image hash Last.fm serves for every artist without a photo: a grey
/// star. Servers pass it through `getArtistInfo2` as if it were a photo.
const String lastFmPlaceholderImageHash = '2a96cbd8b46e442fc41c2b86b821562f';

/// Whether [url] is Last.fm's grey-star placeholder rather than a photo.
bool isLastFmPlaceholderUrl(String url) =>
    url.toLowerCase().contains(lastFmPlaceholderImageHash);

/// Whether [url] is Deezer's picture for an artist without a photo. Deezer
/// leaves the image hash out of the path (`/images/artist//1000x1000-…`).
bool isDeezerPlaceholderPictureUrl(String url) =>
    url.toLowerCase().contains('/images/artist//');

/// The header photo URLs for an artist, best first: the server's photo
/// (large, else medium), then Deezer's.
///
/// Empty strings, URLs that do not parse as absolute and the Last.fm and
/// Deezer placeholders are left out, so the header falls back to the next
/// photo and finally to the plain name header instead of showing a grey star
/// or a blank box. Callers still apply the integration policy to each URL.
List<String> artistHeaderImageUrls({
  String? serverLargeImageUrl,
  String? serverMediumImageUrl,
  String? deezerPictureUrl,
}) {
  final server = <String?>[serverLargeImageUrl, serverMediumImageUrl]
      .map(_usableUrl)
      .nonNulls
      .where((url) => !isLastFmPlaceholderUrl(url))
      .firstOrNull;
  final deezer = switch (_usableUrl(deezerPictureUrl)) {
    final url? when !isDeezerPlaceholderPictureUrl(url) => url,
    _ => null,
  };
  return <String>[?server, if (deezer != null && deezer != server) deezer];
}

String? _usableUrl(String? value) {
  final url = value?.trim() ?? '';
  if (url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  return url;
}
