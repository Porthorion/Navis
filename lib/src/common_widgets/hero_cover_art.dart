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
            // Always use the destination hero's child so the image loads at
            // the destination (high-res) quality from the start of the
            // animation instead of switching resolutions mid-flight.
            // Using toHeroContext for both push and pop avoids the flicker
            // caused by CoverArtImage re-resolving its size (via LayoutBuilder)
            // as the Hero bounds animate between different constraint values.
            final destHero = toHeroContext.widget;
            if (destHero is Hero) {
              return destHero.child;
            }
            // Fallback: use from-hero child if to-hero is not a Hero widget.
            final fromHero = fromHeroContext.widget;
            if (fromHero is Hero) {
              return fromHero.child;
            }
            return const SizedBox.shrink();
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
