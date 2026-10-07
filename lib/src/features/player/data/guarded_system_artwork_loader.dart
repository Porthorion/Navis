import 'package:audio_service/audio_service.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/features/integrations/data/artwork_call_recorder.dart';
import 'package:navis/src/features/integrations/domain/integration_artwork.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';

/// Shares policy and cached files with the app's external artwork surfaces.
class GuardedSystemArtworkLoader {
  new({
    required this._readCacheManager,
    required this._readPolicy,
    required this._readServerHost,
    this.artworkRecorder,
  });

  final BaseCacheManager Function() _readCacheManager;
  final IntegrationPolicy Function() _readPolicy;
  final String? Function() _readServerHost;
  final ArtworkCallRecorder? artworkRecorder;

  bool _isRadio(MediaItem item) =>
      item.extras?['isRadio'] == true || item.id.startsWith('radio:');

  bool isAllowed(MediaItem item) {
    final uri = item.artUri;
    if (uri == null || !isHostedHttpUri(uri)) return false;
    final policy = _readPolicy();
    final serverHost = _readServerHost();
    return _isRadio(item)
        ? integrationAllowsRadioArtworkUri(policy, uri, serverHost: serverHost)
        : integrationAllowsArtworkUri(policy, uri, serverHost: serverHost) &&
              integrationAllowsArtworkHost(policy, uri, serverHost: serverHost);
  }

  /// Checks permission without recording repeated system metadata checks.
  bool checkAllowed(MediaItem item) => isAllowed(item);

  Future<String?> fetch(MediaItem item) async {
    // Check even for a cache hit: refused art must not reach the OS session.
    final uri = item.artUri;
    if (uri == null) return null;
    final allowed = isAllowed(item);
    if (!(artworkRecorder?.checkAllowed(uri, allowed: allowed) ?? allowed)) {
      return null;
    }
    final url = item.artUri!.toString();
    final feature = _isRadio(item) ? IntegrationFeature.radioNowPlaying : null;
    final file = await _readCacheManager().getSingleFile(
      url,
      key: feature == null ? url : coverArtFeatureCacheKey(feature.key, url),
      headers: feature == null
          ? const <String, String>{}
          : coverArtFeatureHeaders(feature.key),
    );
    // A queued download or cache lookup may outlive a policy change.
    return isAllowed(item) ? file.path : null;
  }
}
