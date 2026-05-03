import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/providers/app_providers.dart';

// Re-export constants so that files which import cover_art_image.dart continue
// to access coverArtCacheKey and kCoverArtStandardSize without extra imports.
export 'package:navis/src/common_widgets/cover_art_cache_manager.dart'
    show coverArtCacheKey, coverArtImageCacheKey, kCoverArtStandardSize;

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
    this.semanticLabel,
    this.fadeInDuration = const Duration(milliseconds: 150),
    this.showLoadingPlaceholder = true,
    this.showErrorPlaceholder = true,
    this.lockedSize,
  });

  final String? coverArtId;
  final int? size;
  final double? width;
  final double? height;
  final BoxFit fit;
  final IconData placeholderIcon;
  final BorderRadius? borderRadius;
  final bool circular;

  /// Optional text description read by screen readers. When `null` the image
  /// is treated as decorative and excluded from the accessibility tree.
  final String? semanticLabel;
  final Duration fadeInDuration;
  final bool showLoadingPlaceholder;
  final bool showErrorPlaceholder;

  /// When non-null, overrides all constraint-based size resolution.
  /// Used during hero flight animations to prevent mid-flight URL changes.
  final int? lockedSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = coverArtId?.trim() ?? '';
    if (id.isEmpty) {
      return _withSemantics(_fallback(context));
    }

    final api = ref.watch(subsonicApiProvider);
    if (api == null) {
      return _withSemantics(_fallback(context));
    }

    final cacheManager = ref.watch(coverArtCacheManagerProvider);

    // When the size is fully determined without needing layout constraints
    // (explicit size param or locked hero size), build the image widget
    // immediately — skipping LayoutBuilder entirely. This starts the cache
    // look-up one layout pass earlier, so the decoded image is ready before
    // the hero animation finishes landing. It also guarantees that the URL
    // matches exactly what was cached at the source (same size = same key).
    final preResolved = lockedSize ?? (size != null && size! > 0 ? size : null);
    if (preResolved != null) {
      return _withSemantics(
        _buildImageChild(context, preResolved, api, cacheManager),
      );
    }

    // No explicit size: derive from layout constraints (used only for widgets
    // that intentionally omit a size and rely on their container dimensions,
    // e.g. the now-playing full-screen art).
    return LayoutBuilder(
      builder: (context, constraints) {
        final resolvedSize = _resolveFromConstraints(context, constraints);
        return _withSemantics(
          _buildImageChild(context, resolvedSize, api, cacheManager),
        );
      },
    );
  }

  Widget _buildImageChild(
    BuildContext context,
    int? resolvedSize,
    SubsonicApiClient api,
    CacheManager cacheManager,
  ) {
    final image = CachedNetworkImage(
      imageUrl: api
          .getCoverArtUrl(id: coverArtId!.trim(), size: resolvedSize)
          .toString(),
      cacheKey: coverArtImageCacheKey(coverArtId!, resolvedSize),
      fit: fit,
      width: width,
      height: height,
      cacheManager: cacheManager,
      fadeInDuration: fadeInDuration,
      fadeOutDuration: Duration.zero,
      memCacheWidth: _memCacheSize(width, resolvedSize),
      memCacheHeight: _memCacheSize(height, resolvedSize),
      placeholder: (_, _) =>
          showLoadingPlaceholder ? _fallback(context) : _emptyPlaceholder(),
      errorWidget: (_, _, _) =>
          showErrorPlaceholder ? _fallback(context) : _emptyPlaceholder(),
    );

    Widget child;
    if (circular) {
      child = ClipOval(child: image);
    } else {
      final radius = borderRadius ?? BorderRadius.zero;
      child = radius == BorderRadius.zero
          ? image
          : ClipRRect(borderRadius: radius, child: image);
    }
    return child;
  }

  Widget _withSemantics(Widget child) {
    if (semanticLabel != null) {
      return Semantics(
        image: true,
        label: semanticLabel,
        child: ExcludeSemantics(child: child),
      );
    }
    return ExcludeSemantics(child: child);
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
      child: Icon(
        placeholderIcon,
        size: _placeholderIconSize,
        color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(
          alpha: 0.5,
        ),
      ),
    );
  }

  Widget _emptyPlaceholder() => SizedBox(width: width, height: height);

  /// Scale the placeholder icon relative to the container but keep a sane min.
  /// Guards against double.infinity when the widget fills its parent.
  double get _placeholderIconSize {
    final w = (width != null && width!.isFinite) ? width! : 48.0;
    final h = (height != null && height!.isFinite) ? height! : 48.0;
    final dim = w < h ? w : h;
    final scaled = dim * 0.4;
    return scaled < 20 ? 20 : scaled;
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

  /// Resolves a pixel size from layout [constraints] only (no explicit size).
  /// Called only when no [size] or [lockedSize] was provided to the widget.
  int? _resolveFromConstraints(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    final targetLogical = _targetLogicalExtent(constraints);
    if (targetLogical == null) return null;
    final pixelRatio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final targetPixels = (targetLogical * pixelRatio).ceil();
    if (targetPixels < 96) return 96;
    if (targetPixels > 2048) return 2048;
    return targetPixels;
  }

  double? _targetLogicalExtent(BoxConstraints constraints) {
    final explicitWidth = _finitePositive(width);
    final explicitHeight = _finitePositive(height);
    if (explicitWidth != null || explicitHeight != null) {
      if (explicitWidth == null) {
        return explicitHeight;
      }
      if (explicitHeight == null) {
        return explicitWidth;
      }
      return explicitWidth > explicitHeight ? explicitWidth : explicitHeight;
    }

    final boundedWidth = constraints.hasBoundedWidth
        ? _finitePositive(constraints.maxWidth)
        : null;
    final boundedHeight = constraints.hasBoundedHeight
        ? _finitePositive(constraints.maxHeight)
        : null;
    if (boundedWidth == null && boundedHeight == null) {
      return null;
    }
    if (boundedWidth == null) {
      return boundedHeight;
    }
    if (boundedHeight == null) {
      return boundedWidth;
    }
    return boundedWidth > boundedHeight ? boundedWidth : boundedHeight;
  }

  static double? _finitePositive(double? value) {
    if (value == null || !value.isFinite || value <= 0) {
      return null;
    }
    return value;
  }
}
