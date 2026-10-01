import 'package:audio_service/audio_service.dart';
import 'package:navis/src/utils/credential_redaction.dart';

/// The `MediaItem.extras` key of the local cover file that
/// `NavisAudioHandler` caches for the current song.
const artCacheFileExtra = 'artCacheFile';

/// The local cover file cached for [item], if any.
String? systemArtFile(MediaItem item) {
  final cached = item.extras?[artCacheFileExtra];
  return cached is String && cached.isNotEmpty ? cached : null;
}

/// The cover to show in the system media controls (MPRIS) for [item]: the
/// local cover file once it is cached, otherwise [MediaItem.artUri] only when
/// it carries no account credentials (radio artwork). A Subsonic cover URL is
/// never published, since other processes can read it.
String? systemArtUrl(MediaItem item) {
  final cached = systemArtFile(item);
  if (cached != null) return Uri.file(cached).toString();
  final artUri = item.artUri;
  if (artUri == null || uriCarriesCredentials(artUri)) return null;
  return artUri.toString();
}
