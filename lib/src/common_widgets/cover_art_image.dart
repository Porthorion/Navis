import 'dart:io';

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

/// Maximum concurrent HTTP connections per host for cover art image loading.
///
/// Limiting this prevents rapid library-grid scrolling from saturating the
/// HTTP connection pool and blocking detail-page images from starting promptly.
/// Four concurrent connections is enough to fill a 2 × 2 album grid quickly
/// while keeping slots available for higher-priority detail-page requests.
const int _coverArtMaxConnectionsPerHost = 4;

// ---------------------------------------------------------------------------
// Connection-limited FileService (dart:io only, no package:http dependency)
// ---------------------------------------------------------------------------

/// [FileService] backed by a connection-limited [HttpClient].
///
/// Injected into every [CacheManager] created by [createCoverArtCacheManager]
/// so that at most [_coverArtMaxConnectionsPerHost] cover-art downloads run
/// concurrently per host.  Excess requests are queued by [HttpClient] and
/// start as soon as a connection slot becomes free, ensuring that a detail
/// page opened after rapid grid scrolling does not have to wait behind 20+
/// in-progress thumbnail downloads (issue #32).
class _IoHttpFileService implements FileService {
  _IoHttpFileService() {
    _client = HttpClient()
      ..maxConnectionsPerHost = _coverArtMaxConnectionsPerHost;
  }

  late final HttpClient _client;

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    final request = await _client.getUrl(Uri.parse(url));
    headers.forEach(request.headers.set);
    final response = await request.close();
    return _IoHttpFileServiceResponse(response);
  }
}

class _IoHttpFileServiceResponse implements FileServiceResponse {
  const _IoHttpFileServiceResponse(this._response);

  final HttpClientResponse _response;

  @override
  int get statusCode => _response.statusCode;

  @override
  Stream<List<int>> get content => _response;

  @override
  int? get contentLength {
    final cl = _response.contentLength;
    return cl < 0 ? null : cl;
  }

  @override
  String? get eTag => _response.headers.value(HttpHeaders.etagHeader);

  @override
  DateTime get validTill {
    // Honour Cache-Control: max-age when present.
    final cc = _response.headers.value(HttpHeaders.cacheControlHeader);
    if (cc != null) {
      final match = RegExp(r'max-age=(\d+)').firstMatch(cc);
      if (match != null) {
        final maxAge = int.tryParse(match.group(1)!);
        if (maxAge != null) {
          return DateTime.now().add(Duration(seconds: maxAge));
        }
      }
    }
    final expires = _response.headers.expires;
    if (expires != null) return expires;
    // Fall back to the same 30-day stale period used by the cache config.
    return DateTime.now().add(const Duration(days: 30));
  }

  @override
  String? get fileExtension {
    final ct = _response.headers.contentType;
    if (ct == null) return null;
    return '.${ct.subType}'; // '.jpeg', '.png', etc.
  }
}

// ---------------------------------------------------------------------------
// Cache manager factory
// ---------------------------------------------------------------------------

/// Creates a [CacheManager] for cover art images.
///
/// [maxNrOfCacheObjects] controls how many image files are stored on disk.
/// Pass `0` (the default) for an effectively unlimited cache.
///
/// Every instance uses [_IoHttpFileService] to cap concurrent downloads to
/// [_coverArtMaxConnectionsPerHost] per host (issue #32).
CacheManager createCoverArtCacheManager({int maxNrOfCacheObjects = 0}) {
  final cap = maxNrOfCacheObjects <= 0
      ? _coverArtCacheUnlimited
      : maxNrOfCacheObjects;
  return CacheManager(
    Config(
      coverArtCacheKey,
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: cap,
      fileService: _IoHttpFileService(),
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
  return dao.watchCoverArtCacheMaxObjects().map(
    (maxObjects) => createCoverArtCacheManager(
      maxNrOfCacheObjects: maxObjects,
    ),
  );
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
    this.semanticLabel,
    this.fadeInDuration = const Duration(milliseconds: 150),
    this.showLoadingPlaceholder = true,
    this.showErrorPlaceholder = true,
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

    final cacheManager =
        ref.watch(coverArtCacheManagerProvider).asData?.value ??
        defaultCoverArtCacheManager;
    return LayoutBuilder(
      builder: (context, constraints) {
        final resolvedSize = _resolveRequestedSize(context, constraints);
        final image = CachedNetworkImage(
          imageUrl: api.getCoverArtUrl(id: id, size: resolvedSize).toString(),
          cacheKey: '$id:${resolvedSize ?? 0}',
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

        // Wrap with Semantics when a label is provided; otherwise exclude from
        // the accessibility tree (image is purely decorative).
        return _withSemantics(child);
      },
    );
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
  double get _placeholderIconSize {
    final w = width ?? 48;
    final h = height ?? 48;
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

  int? _resolveRequestedSize(BuildContext context, BoxConstraints constraints) {
    final explicitSize = size != null && size! > 0 ? size! : null;
    final targetLogical = _targetLogicalExtent(constraints);
    if (targetLogical == null) {
      return explicitSize;
    }

    final pixelRatio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final targetPixels = (targetLogical * pixelRatio).ceil();
    final resolved = (explicitSize != null && explicitSize > targetPixels)
        ? explicitSize
        : targetPixels;
    if (resolved < 96) {
      return 96;
    }
    if (resolved > 2048) {
      return 2048;
    }
    return resolved;
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
