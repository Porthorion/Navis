import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/features/integrations/domain/integration_artwork.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/providers/app_providers.dart';

/// A network image whose URL may point anywhere but the user's own server:
/// artist photos, radio station art, Deezer and ListenBrainz covers.
///
/// It checks the integration policy first (see
/// [integrationAllowsArtworkUri]) and then loads through the shared cover-art
/// cache manager, which enforces the same policy again before any request.
/// While the policy refuses the URL, or when loading fails, it shows
/// [fallbackBuilder] instead, so callers keep their own placeholder.
///
/// Radio art needs `radio.nowPlaying` and the server-linked artwork service.
/// A [feature] is sent with the request, so the loader checks that feature's
/// switch again right before the download is dispatched.
class ExternalArtworkImage extends ConsumerWidget {
  const new({
    required this.url,
    required this.fallbackBuilder,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.feature,
    super.key,
  });

  final String url;

  /// What to show while the image is not allowed or cannot load.
  final WidgetBuilder fallbackBuilder;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final Alignment alignment;

  /// The feature the image belongs to, when the host does not say (radio
  /// station art). Overrides the host mapping.
  final IntegrationFeature? feature;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) {
      return fallbackBuilder(context);
    }
    final serverHost = ref.watch(serverHostProvider);
    final allowed = ref.watch(
      integrationPolicyProvider.select(
        (policy) => integrationAllowsArtworkUri(
          policy,
          uri,
          serverHost: serverHost,
          feature: feature,
        ),
      ),
    );
    if (!allowed) {
      return fallbackBuilder(context);
    }
    return CachedNetworkImage(
      imageUrl: url.trim(),
      cacheManager: ref.watch(coverArtCacheManagerProvider),
      // Names the feature so a download queued for it is refused at dispatch
      // once the feature is switched off.
      httpHeaders: feature == null
          ? null
          : coverArtFeatureHeaders(feature!.key),
      // Tagged loads never share a download with untagged loads of the URL.
      cacheKey: feature == null
          ? null
          : coverArtFeatureCacheKey(feature!.key, url.trim()),
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      errorWidget: (context, _, _) => fallbackBuilder(context),
    );
  }
}
