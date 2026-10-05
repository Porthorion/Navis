import 'package:navis/src/features/integrations/domain/integration_feature.dart';

/// The feature whose switches must be on before an image at [uri] loads, or
/// null when the image may always load because it comes from the user's own
/// server.
///
/// [serverHost] is the host of the user's Subsonic server. Everything else is
/// mapped by host:
///
/// - `dzcdn.net` and `deezer.com` (and subdomains): Deezer artist images.
/// - `last.fm`, `lastfm.*` and `audioscrobbler.com`: server-linked artwork,
///   because the URL came from the server's own metadata.
/// - `listenbrainz.org` and `coverartarchive.org`: ListenBrainz weekly
///   playlists.
/// - any other host: server-linked artwork.
///
/// Radio station art has arbitrary hosts, so it cannot be told apart by host;
/// callers pass `radio.nowPlaying` explicitly (see `ExternalArtworkImage`).
IntegrationFeature? integrationFeatureForArtworkUri(
  Uri uri, {
  required String? serverHost,
}) {
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return null;
  final server = serverHost?.toLowerCase();
  if (server != null && server.isNotEmpty && host == server) return null;
  if (_matches(host, 'dzcdn.net') || _matches(host, 'deezer.com')) {
    return IntegrationFeature.deezerArtistImages;
  }
  if (_matches(host, 'last.fm') ||
      _matches(host, 'audioscrobbler.com') ||
      _isLastFmHost(host)) {
    return IntegrationFeature.artworkServerLinked;
  }
  if (_matches(host, 'listenbrainz.org') ||
      _matches(host, 'coverartarchive.org')) {
    return IntegrationFeature.listenBrainzWeeklyPlaylists;
  }
  return IntegrationFeature.artworkServerLinked;
}

/// Whether an image at [uri] may load under [policy].
///
/// Only the master, service and feature switches matter; artwork needs no
/// credential, so this uses [IntegrationPolicy.isEnabled]. [feature]
/// overrides the host mapping, for callers that know why the URL exists
/// (radio station art).
bool integrationAllowsArtworkUri(
  IntegrationPolicy policy,
  Uri uri, {
  required String? serverHost,
  IntegrationFeature? feature,
}) {
  final mapped = integrationFeatureForArtworkUri(uri, serverHost: serverHost);
  if (mapped == null) return true;
  return policy.isEnabled(feature ?? mapped);
}

/// Feature-level check for the shared file service: [integrationAllowsArtworkUri]
/// for the feature the request named by [featureKey] (see
/// `coverArtFeatureHeader`). An unknown key is refused.
bool integrationAllowsArtworkFeatureKey(
  IntegrationPolicy policy,
  Uri uri,
  String featureKey, {
  required String? serverHost,
}) {
  final feature = IntegrationFeature.tryParse(featureKey);
  if (feature == null) return false;
  return integrationAllowsArtworkUri(
    policy,
    uri,
    serverHost: serverHost,
    feature: feature,
  );
}

/// Service-level variant used by the shared file service, which cannot know
/// why a URL is loaded: the master and service switches for the host's
/// service.
bool integrationAllowsArtworkHost(
  IntegrationPolicy policy,
  Uri uri, {
  required String? serverHost,
}) {
  final mapped = integrationFeatureForArtworkUri(uri, serverHost: serverHost);
  if (mapped == null) return true;
  return policy.isServiceEnabled(mapped.service);
}

bool _matches(String host, String domain) =>
    host == domain || host.endsWith('.$domain');

bool _isLastFmHost(String host) {
  final labels = host.split('.');
  return labels.any((label) => label == 'lastfm');
}

/// The user's server is always allowed. External radio art needs both radio
/// metadata permission and the artwork host's service enabled.
bool integrationAllowsRadioArtworkUri(
  IntegrationPolicy policy,
  Uri uri, {
  required String? serverHost,
}) {
  if (integrationFeatureForArtworkUri(uri, serverHost: serverHost) == null) {
    return true;
  }
  return policy.allows(IntegrationFeature.radioNowPlaying) &&
      integrationAllowsArtworkHost(policy, uri, serverHost: serverHost);
}
