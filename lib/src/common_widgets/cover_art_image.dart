import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/providers/app_providers.dart';

final _coverArtCacheManager = CacheManager(
  Config(
    'navis_cover_art_cache',
    stalePeriod: const Duration(days: 30),
    maxNrOfCacheObjects: 2500,
  ),
);

class CoverArtImage extends ConsumerWidget {
  const CoverArtImage({
    required this.coverArtId,
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
  final int? size;
  final double? width;
  final double? height;
  final BoxFit fit;
  final IconData placeholderIcon;
  final BorderRadius? borderRadius;
  final bool circular;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = coverArtId?.trim() ?? '';
    if (id.isEmpty) {
      return _fallback(context);
    }

    final api = ref.watch(subsonicApiProvider);
    if (api == null) {
      return _fallback(context);
    }

    final image = CachedNetworkImage(
      imageUrl: api.getCoverArtUrl(id: id, size: size).toString(),
      cacheKey: '$id:${size ?? 0}',
      fit: fit,
      width: width,
      height: height,
      cacheManager: _coverArtCacheManager,
      placeholder: (_, _) => _fallback(context),
      errorWidget: (_, _, _) => _fallback(context),
    );

    if (circular) {
      return ClipOval(child: image);
    }
    final radius = borderRadius ?? BorderRadius.zero;
    if (radius == BorderRadius.zero) {
      return image;
    }
    return ClipRRect(
      borderRadius: radius,
      child: image,
    );
  }

  Widget _fallback(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: circular ? null : borderRadius ?? BorderRadius.zero,
        shape: circular ? BoxShape.circle : BoxShape.rectangle,
      ),
      alignment: Alignment.center,
      child: Icon(placeholderIcon),
    );
  }
}
