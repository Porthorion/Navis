import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';

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

  @override
  Widget build(BuildContext context) {
    return Hero(
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
            // Use the source element's image — it's already loaded and cached,
            // so the flight is smooth with no placeholder flashes.
            // On push:  source = fromHeroContext (the list item)
            // On pop:   source = toHeroContext   (the screen we're returning to)
            final sourceContext = flightDirection == HeroFlightDirection.push
                ? fromHeroContext
                : toHeroContext;

            // Capture the rendered pixel size at flight start so the image URL
            // stays constant as Hero bounds animate between screens.
            final renderBox = sourceContext.findRenderObject();
            final pixelRatio =
                MediaQuery.maybeDevicePixelRatioOf(flightContext) ?? 1.0;
            int? lockedSize;
            if (renderBox is RenderBox && renderBox.hasSize) {
              final longestSide = renderBox.size.longestSide;
              final pixels = (longestSide * pixelRatio).ceil();
              lockedSize = pixels.clamp(96, 2048);
            }

            // Reconstruct CoverArtImage with the frozen size.
            // fadeInDuration: zero because the image is already in cache — no fade
            // needed and a fade would look odd during an animation.
            return CoverArtImage(
              coverArtId: coverArtId,
              size: size,
              width: width,
              height: height,
              fit: fit,
              placeholderIcon: placeholderIcon,
              borderRadius: borderRadius,
              circular: circular,
              fadeInDuration: Duration.zero,
              lockedSize: lockedSize,
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
      ),
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
