import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';

class HeroCoverArt extends StatelessWidget {
  const HeroCoverArt({
    required this.coverArtId,
    required this.heroTag,
    super.key,
    this.size,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholderIcon = Icons.album_outlined,
    this.borderRadius,
    this.circular = false,
    this.showLoadingPlaceholder = true,
    this.fadeInDuration,
    this.loadPriority = CoverArtLoadPriority.visible,
    this.isExternalSource = false,
    this.remoteSourceIndicatorPolicy = RemoteSourceIndicatorPolicy.automatic,
  });

  final String? coverArtId;
  final String heroTag;
  final int? size;
  final double? width;
  final double? height;
  final BoxFit fit;
  final IconData placeholderIcon;
  final BorderRadius? borderRadius;
  final bool circular;

  /// Whether to show a placeholder icon/color while the image loads.
  final bool showLoadingPlaceholder;

  /// Duration for the fade-in once the image is loaded. Defaults to the
  /// [CoverArtImage] default (150 ms). Use a longer value (e.g., 350 ms)
  /// for full-bleed art so the image appears smoothly after the hero.
  final Duration? fadeInDuration;
  final CoverArtLoadPriority loadPriority;
  final bool isExternalSource;
  final RemoteSourceIndicatorPolicy remoteSourceIndicatorPolicy;

  @override
  Widget build(BuildContext context) {
    final hero = Hero(
      tag: heroTag,
      transitionOnUserGestures: true,
      flightShuttleBuilder:
          (
            flightContext,
            animation,
            flightDirection,
            fromHeroContext,
            toHeroContext,
          ) {
            // A destination Hero's shuttle takes precedence in Flutter. Read
            // the actual source Hero instead of this destination's dimensions,
            // otherwise a 600 px card can turn into a cold 300 px request
            // during its flight to the desktop detail header.
            final sourceContext = flightDirection == HeroFlightDirection.push
                ? fromHeroContext
                : toHeroContext;
            final sourceHero = sourceContext.widget;
            final sourceImage = sourceHero is Hero ? sourceHero.child : null;
            final sourceCoverArt = sourceImage is CoverArtImage
                ? sourceImage
                : null;

            // Preserve the exact source cache key for the entire flight. Only
            // fall back to the rendered size for a Hero whose source did not
            // have an explicit image size.
            var lockedSize = sourceCoverArt?.lockedSize ?? sourceCoverArt?.size;
            if (lockedSize == null) {
              final renderBox = sourceContext.findRenderObject();
              final pixelRatio =
                  MediaQuery.maybeDevicePixelRatioOf(flightContext) ?? 1.0;
              if (renderBox is RenderBox && renderBox.hasSize) {
                final longestSide = renderBox.size.longestSide;
                final pixels = (longestSide * pixelRatio).ceil();
                lockedSize = pixels.clamp(96, 2048);
              }
            }

            final sourceRadius =
                sourceCoverArt?.borderRadius ?? BorderRadius.zero;
            final destinationRadius = borderRadius ?? BorderRadius.zero;
            return AnimatedBuilder(
              animation: animation,
              builder: (context, child) {
                return ClipRRect(
                  borderRadius: BorderRadiusGeometry.lerp(
                    sourceRadius,
                    destinationRadius,
                    animation.value,
                  )!,
                  child: child,
                );
              },
              child: CoverArtImage(
                coverArtId: sourceCoverArt?.coverArtId ?? coverArtId,
                size: lockedSize,
                fit: sourceCoverArt?.fit ?? fit,
                placeholderIcon:
                    sourceCoverArt?.placeholderIcon ?? placeholderIcon,
                fadeInDuration: Duration.zero,
                lockedSize: lockedSize,
                loadPriority: CoverArtLoadPriority.critical,
                isExternalSource:
                    sourceCoverArt?.isExternalSource ?? isExternalSource,
                remoteSourceIndicatorPolicy: RemoteSourceIndicatorPolicy.hidden,
                gaplessPlayback: true,
              ),
            );
          },
      child: CoverArtImage(
        coverArtId: coverArtId,
        size: size,
        width: width,
        height: height,
        fit: fit,
        placeholderIcon: placeholderIcon,
        borderRadius: borderRadius,
        circular: circular,
        showLoadingPlaceholder: showLoadingPlaceholder,
        fadeInDuration: fadeInDuration ?? const Duration(milliseconds: 150),
        loadPriority: loadPriority,
        isExternalSource: isExternalSource,
        remoteSourceIndicatorPolicy: RemoteSourceIndicatorPolicy.hidden,
        gaplessPlayback: true,
      ),
    );
    return RemoteSourceArtworkOverlay(
      isRemote: isExternalSource,
      policy: remoteSourceIndicatorPolicy,
      width: width,
      height: height,
      child: hero,
    );
  }
}

String buildCoverArtHeroTag({
  required String? coverArtId,
  required String context,
  String? entityId,
}) {
  final normalizedEntityId = entityId?.trim();
  if (normalizedEntityId != null && normalizedEntityId.isNotEmpty) {
    return 'cover_art_${context}_$normalizedEntityId';
  }
  final id = coverArtId?.trim() ?? 'unknown';
  return 'cover_art_${context}_$id';
}
