import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Shared cover art cache key used by both the cache manager and clear logic.
const String coverArtCacheKey = 'navis_cover_art_cache';

/// Sentinel value meaning «no object-count cap» — enough covers even for a
/// 100 k-track library where every album has a unique thumbnail at three sizes.
const int _coverArtCacheUnlimited = 999999;

/// Creates a [CacheManager] for cover art images.
///
/// [maxNrOfCacheObjects] controls how many image files are stored on disk.
/// Pass `0` (the default) for an effectively unlimited cache.
CacheManager createCoverArtCacheManager({int maxNrOfCacheObjects = 0}) {
  final cap = maxNrOfCacheObjects <= 0
      ? _coverArtCacheUnlimited
      : maxNrOfCacheObjects;
  return CacheManager(
    Config(
      coverArtCacheKey,
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: cap,
    ),
  );
}

/// Module-level fallback instance — used before the provider resolves.
final CacheManager defaultCoverArtCacheManager = createCoverArtCacheManager();

/// Reactive cover art [CacheManager] provider.
///
/// Watches the user's cover art cache limit setting and rebuilds on changes,
/// so the active [CacheManager] always reflects the configured cap.
final coverArtCacheManagerProvider = StreamProvider<CacheManager>((ref) {
  final dao = ref.watch(navisDatabaseProvider).appSettingsDao;
  return dao
      .watchCoverArtCacheMaxObjects()
      .map((maxObjects) => createCoverArtCacheManager(
            maxNrOfCacheObjects: maxObjects,
          ));
});

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

    final cacheManager =
        ref.watch(coverArtCacheManagerProvider).asData?.value ??
        defaultCoverArtCacheManager;

    final image = CachedNetworkImage(
      imageUrl: api.getCoverArtUrl(id: id, size: size).toString(),
      cacheKey: '$id:${size ?? 0}',
      fit: fit,
      width: width,
      height: height,
      cacheManager: cacheManager,
      fadeInDuration: const Duration(milliseconds: 150),
      fadeOutDuration: Duration.zero,
      memCacheWidth: _memCacheSize(width, size),
      memCacheHeight: _memCacheSize(height, size),
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

  /// Compute a memory-cache dimension to keep decoded images small in RAM.
  /// Returns null when no useful constraint is available.
  static int? _memCacheSize(double? layoutDimension, int? requestedSize) {
    if (layoutDimension != null &&
        layoutDimension > 0 &&
        layoutDimension.isFinite) {
      // Use 2× the layout size for crisp Retina display.
      return (layoutDimension * 2).ceil();
    }
    if (requestedSize != null && requestedSize > 0) {
      return requestedSize;
    }
    return null;
  }
}
