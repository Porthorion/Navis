import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
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
class ExternalArtworkImage extends ConsumerStatefulWidget {
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
  ConsumerState<ExternalArtworkImage> createState() =>
      _ExternalArtworkImageState();
}

class _ExternalArtworkImageState extends ConsumerState<ExternalArtworkImage> {
  @override
  void initState() {
    super.initState();
    // Register the epoch listener before the image listener, so a policy
    // change clears deduplication before this image reports its refusal.
    ref.read(artworkCallRecorderProvider);
    ref.listenManual(integrationPolicyProvider, (_, _) => _recordRefusal());
    ref.listenManual(serverHostProvider, (_, _) => _recordRefusal());
    _recordRefusal();
  }

  @override
  void didUpdateWidget(ExternalArtworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.feature != widget.feature) {
      _recordRefusal();
    }
  }

  void _recordRefusal() {
    final uri = Uri.tryParse(widget.url.trim());
    if (uri == null || !uri.hasScheme) return;
    ref
        .read(artworkCallRecorderProvider)
        .checkAllowed(
          uri,
          allowed: integrationAllowsArtworkUri(
            ref.read(integrationPolicyProvider),
            uri,
            serverHost: ref.read(serverHostProvider),
            feature: widget.feature,
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(widget.url.trim());
    if (uri == null || !uri.hasScheme) {
      return widget.fallbackBuilder(context);
    }
    final serverHost = ref.watch(serverHostProvider);
    final allowed = ref.watch(
      integrationPolicyProvider.select(
        (policy) => integrationAllowsArtworkUri(
          policy,
          uri,
          serverHost: serverHost,
          feature: widget.feature,
        ),
      ),
    );
    if (!allowed) {
      return widget.fallbackBuilder(context);
    }
    return CachedNetworkImage(
      imageUrl: widget.url.trim(),
      cacheManager: ref.watch(coverArtCacheManagerProvider),
      // Names the feature so a download queued for it is refused at dispatch
      // once the feature is switched off.
      httpHeaders: widget.feature == null
          ? null
          : coverArtFeatureHeaders(widget.feature!.key),
      // Tagged loads never share a download with untagged loads of the URL.
      cacheKey: widget.feature == null
          ? null
          : coverArtFeatureCacheKey(widget.feature!.key, widget.url.trim()),
      // Bounds the decode so a decompression bomb cannot exhaust memory. Width
      // only: with both set CachedNetworkImage stretches to an exact box.
      memCacheWidth: kMaxArtworkDecodeEdge,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.alignment,
      errorWidget: (context, _, _) => widget.fallbackBuilder(context),
    );
  }
}
