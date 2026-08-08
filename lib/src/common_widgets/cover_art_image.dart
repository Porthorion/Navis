import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/common_widgets/external_source_badge.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:visibility_detector/visibility_detector.dart';

// Re-export constants so that files which import cover_art_image.dart continue
// to access coverArtCacheKey and kCoverArtStandardSize without extra imports.
export 'package:navis/src/common_widgets/cover_art_cache_manager.dart'
    show
        CoverArtLoadPriority,
        coverArtCacheKey,
        coverArtImageCacheKey,
        kCoverArtStandardSize;

class CoverArtImage extends ConsumerStatefulWidget {
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
    this.loadPriority = CoverArtLoadPriority.visible,
    this.preloadScreens = 1.0,
    this.isExternalSource = false,
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

  /// Controls whether this image may start network work immediately or should
  /// wait for viewport visibility.
  final CoverArtLoadPriority loadPriority;

  /// Number of viewport extents around the visible scroll area that should
  /// count as interested for normal visible-priority loading.
  ///
  /// This lets list/grid art warm before it reaches the screen without keeping
  /// far-offscreen requests alive.
  final double preloadScreens;

  /// Whether this item is available only through an external server catalog.
  final bool isExternalSource;

  @override
  ConsumerState<CoverArtImage> createState() => _CoverArtImageState();
}

class _CoverArtImageState extends ConsumerState<CoverArtImage> {
  final Key _visibilityKey = UniqueKey();

  FileInfo? _cachedFileInfo;
  String? _cacheProbeKey;
  CacheManager? _cacheProbeManager;
  CoverArtLoadInterest? _interest;
  String? _interestKey;
  CoverArtLoadPriority? _interestPriority;
  ScrollPosition? _scrollPosition;
  String? _renderedNetworkCacheKey;
  var _isVisible = false;
  var _isInLoadWindow = false;
  var _loadWindowCheckScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncScrollPosition();
    _scheduleLoadWindowCheck();
  }

  @override
  void didUpdateWidget(covariant CoverArtImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loadPriority != widget.loadPriority ||
        oldWidget.preloadScreens != widget.preloadScreens) {
      _scheduleLoadWindowCheck();
    }
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_handleScrollPositionChanged);
    _clearInterest();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.coverArtId?.trim() ?? '';
    if (id.isEmpty) {
      _clearInterest();
      return _withExternalSourceBadge(
        context,
        _withSemantics(_fallback(context)),
      );
    }

    final api = ref.watch(subsonicApiProvider);
    if (api == null) {
      _clearInterest();
      return _withExternalSourceBadge(
        context,
        _withSemantics(_fallback(context)),
      );
    }

    final cacheManager = ref.watch(coverArtCacheManagerProvider);
    final coordinator = ref.watch(coverArtLoadCoordinatorProvider);

    // When the size is fully determined without needing layout constraints
    // (explicit size param or locked hero size), build without LayoutBuilder so
    // the cache lookup starts one layout pass earlier.
    final preResolved =
        widget.lockedSize ??
        (widget.size != null && widget.size! > 0 ? widget.size : null);
    if (preResolved != null) {
      return _buildResolved(
        context: context,
        resolvedSize: preResolved,
        api: api,
        cacheManager: cacheManager,
        coordinator: coordinator,
      );
    }

    // No explicit size: derive from layout constraints (used only for widgets
    // that intentionally omit a size and rely on their container dimensions).
    return LayoutBuilder(
      builder: (context, constraints) {
        final resolvedSize = _resolveFromConstraints(context, constraints);
        return _buildResolved(
          context: context,
          resolvedSize: resolvedSize,
          api: api,
          cacheManager: cacheManager,
          coordinator: coordinator,
        );
      },
    );
  }

  Widget _buildResolved({
    required BuildContext context,
    required int? resolvedSize,
    required SubsonicApiClient api,
    required CacheManager cacheManager,
    required CoverArtLoadCoordinator coordinator,
  }) {
    final id = widget.coverArtId!.trim();
    final cacheKey = coverArtImageCacheKey(id, resolvedSize);
    _scheduleLoadWindowCheck();
    _startCacheProbe(cacheManager, cacheKey);
    _syncInterest(coordinator, cacheKey, _activePriority);

    final wantsNetwork =
        widget.loadPriority == CoverArtLoadPriority.critical ||
        widget.loadPriority == CoverArtLoadPriority.background ||
        _wantsVisibleLoad;
    final cachedFile = _cachedFileInfo?.file;
    final networkAllowed = wantsNetwork || _renderedNetworkCacheKey == cacheKey;
    final child = networkAllowed
        ? _buildNetworkImageChild(context, resolvedSize, api, cacheManager)
        : cachedFile != null
        ? _buildFileImageChild(context, cachedFile)
        : (widget.showLoadingPlaceholder
              ? _fallback(context)
              : _emptyPlaceholder());

    return _withVisibility(
      _withExternalSourceBadge(context, _withSemantics(child)),
    );
  }

  CoverArtLoadPriority? get _activePriority {
    switch (widget.loadPriority) {
      case CoverArtLoadPriority.critical:
        return CoverArtLoadPriority.critical;
      case CoverArtLoadPriority.background:
        return CoverArtLoadPriority.background;
      case CoverArtLoadPriority.visible:
        return _wantsVisibleLoad ? CoverArtLoadPriority.visible : null;
    }
  }

  bool get _wantsVisibleLoad => _isVisible || _isInLoadWindow;

  void _startCacheProbe(CacheManager cacheManager, String cacheKey) {
    if (_cacheProbeKey == cacheKey &&
        identical(_cacheProbeManager, cacheManager)) {
      return;
    }
    _cacheProbeKey = cacheKey;
    _cacheProbeManager = cacheManager;
    _cachedFileInfo = null;
    unawaited(
      cacheManager
          .getFileFromCache(cacheKey)
          .then(
            (fileInfo) {
              if (!mounted ||
                  _cacheProbeKey != cacheKey ||
                  !identical(_cacheProbeManager, cacheManager)) {
                return;
              }
              setState(() {
                _cachedFileInfo = fileInfo;
              });
            },
            onError: (_) {
              if (!mounted ||
                  _cacheProbeKey != cacheKey ||
                  !identical(_cacheProbeManager, cacheManager)) {
                return;
              }
              setState(() {
                _cachedFileInfo = null;
              });
            },
          ),
    );
  }

  void _syncInterest(
    CoverArtLoadCoordinator coordinator,
    String cacheKey,
    CoverArtLoadPriority? priority,
  ) {
    if (_interestKey == cacheKey && _interestPriority == priority) {
      return;
    }
    _clearInterest();
    if (priority == null) {
      return;
    }
    _interestKey = cacheKey;
    _interestPriority = priority;
    _interest = coordinator.trackInterest(cacheKey, priority);
  }

  void _clearInterest() {
    _interest?.dispose();
    _interest = null;
    _interestKey = null;
    _interestPriority = null;
  }

  Widget _withVisibility(Widget child) {
    if (widget.loadPriority != CoverArtLoadPriority.visible) {
      return child;
    }
    return VisibilityDetector(
      key: _visibilityKey,
      onVisibilityChanged: (info) {
        if (!mounted) {
          return;
        }
        final nextVisible = info.visibleFraction > 0;
        if (_isVisible == nextVisible) {
          return;
        }
        setState(() {
          _isVisible = nextVisible;
        });
      },
      child: child,
    );
  }

  void _syncScrollPosition() {
    final nextPosition = Scrollable.maybeOf(context)?.position;
    if (identical(nextPosition, _scrollPosition)) {
      return;
    }
    _scrollPosition?.removeListener(_handleScrollPositionChanged);
    _scrollPosition = nextPosition;
    _scrollPosition?.addListener(_handleScrollPositionChanged);
  }

  void _handleScrollPositionChanged() {
    _scheduleLoadWindowCheck();
  }

  void _scheduleLoadWindowCheck() {
    if (!mounted ||
        widget.loadPriority != CoverArtLoadPriority.visible ||
        _loadWindowCheckScheduled) {
      return;
    }
    _loadWindowCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadWindowCheckScheduled = false;
      if (!mounted) {
        return;
      }
      _syncScrollPosition();
      final nextInLoadWindow = _computeIsInLoadWindow();
      if (_isInLoadWindow == nextInLoadWindow) {
        return;
      }
      setState(() {
        _isInLoadWindow = nextInLoadWindow;
      });
    });
  }

  bool _computeIsInLoadWindow() {
    final scrollable = Scrollable.maybeOf(context);
    final viewportRenderObject = scrollable?.context.findRenderObject();
    final renderObject = context.findRenderObject();
    if (scrollable == null ||
        viewportRenderObject is! RenderBox ||
        renderObject is! RenderBox ||
        !viewportRenderObject.hasSize ||
        !renderObject.hasSize ||
        !viewportRenderObject.attached ||
        !renderObject.attached) {
      return _isVisible;
    }

    final viewportOrigin = viewportRenderObject.localToGlobal(Offset.zero);
    final childOrigin = renderObject.localToGlobal(Offset.zero);
    final viewportRect = viewportOrigin & viewportRenderObject.size;
    final childRect = childOrigin & renderObject.size;
    final preloadScreens = widget.preloadScreens.isFinite
        ? widget.preloadScreens.clamp(0.0, 10.0)
        : 0.0;
    final loadRect = Rect.fromLTRB(
      viewportRect.left - viewportRect.width * preloadScreens,
      viewportRect.top - viewportRect.height * preloadScreens,
      viewportRect.right + viewportRect.width * preloadScreens,
      viewportRect.bottom + viewportRect.height * preloadScreens,
    );
    return loadRect.overlaps(childRect);
  }

  Widget _buildNetworkImageChild(
    BuildContext context,
    int? resolvedSize,
    SubsonicApiClient api,
    CacheManager cacheManager,
  ) {
    final cacheKey = coverArtImageCacheKey(widget.coverArtId!, resolvedSize);
    final image = CachedNetworkImage(
      imageUrl: api
          .getCoverArtUrl(id: widget.coverArtId!.trim(), size: resolvedSize)
          .toString(),
      cacheKey: cacheKey,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      cacheManager: cacheManager,
      fadeInDuration: widget.fadeInDuration,
      fadeOutDuration: Duration.zero,
      memCacheWidth: _memCacheSize(widget.width, resolvedSize),
      memCacheHeight: _memCacheSize(widget.height, resolvedSize),
      imageBuilder: (context, imageProvider) {
        _renderedNetworkCacheKey = cacheKey;
        return Image(
          image: imageProvider,
          fit: widget.fit,
          width: widget.width,
          height: widget.height,
        );
      },
      placeholder: (_, _) => widget.showLoadingPlaceholder
          ? _fallback(context)
          : _emptyPlaceholder(),
      errorWidget: (_, _, _) => widget.showErrorPlaceholder
          ? _fallback(context)
          : _emptyPlaceholder(),
    );
    return _clip(image);
  }

  Widget _buildFileImageChild(BuildContext context, File file) {
    final image = Image.file(
      file,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      errorBuilder: (_, _, _) => widget.showErrorPlaceholder
          ? _fallback(context)
          : _emptyPlaceholder(),
    );
    return _clip(image);
  }

  Widget _clip(Widget child) {
    if (widget.circular) {
      return ClipOval(child: child);
    }
    final radius = widget.borderRadius ?? BorderRadius.zero;
    return radius == BorderRadius.zero
        ? child
        : ClipRRect(borderRadius: radius, child: child);
  }

  Widget _withSemantics(Widget child) {
    if (widget.semanticLabel != null) {
      return Semantics(
        image: true,
        label: widget.semanticLabel,
        child: ExcludeSemantics(child: child),
      );
    }
    return ExcludeSemantics(child: child);
  }

  Widget _withExternalSourceBadge(BuildContext context, Widget child) {
    if (!widget.isExternalSource) {
      return child;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final explicitWidth = _finitePositive(widget.width);
        final explicitHeight = _finitePositive(widget.height);
        final constrainedWidth = constraints.hasBoundedWidth
            ? _finitePositive(constraints.maxWidth)
            : null;
        final constrainedHeight = constraints.hasBoundedHeight
            ? _finitePositive(constraints.maxHeight)
            : null;
        final width = explicitWidth ?? constrainedWidth;
        final height = explicitHeight ?? constrainedHeight;
        final extent = width == null
            ? height
            : height == null
            ? width
            : width < height
            ? width
            : height;
        final badgeSize = extent != null && extent >= 120 ? 24.0 : 18.0;
        final inset = badgeSize == 24 ? 6.0 : 4.0;
        return Stack(
          fit: StackFit.passthrough,
          clipBehavior: Clip.none,
          children: <Widget>[
            child,
            Positioned(
              top: inset,
              left: inset,
              child: ExternalSourceBadge(size: badgeSize),
            ),
          ],
        );
      },
    );
  }

  Widget _fallback(BuildContext context) {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: widget.circular
            ? null
            : widget.borderRadius ?? BorderRadius.zero,
        shape: widget.circular ? BoxShape.circle : BoxShape.rectangle,
      ),
      alignment: Alignment.center,
      child: Icon(
        widget.placeholderIcon,
        size: _placeholderIconSize,
        color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(
          alpha: 0.5,
        ),
      ),
    );
  }

  Widget _emptyPlaceholder() {
    return SizedBox(width: widget.width, height: widget.height);
  }

  /// Scale the placeholder icon relative to the container but keep a sane min.
  /// Guards against double.infinity when the widget fills its parent.
  double get _placeholderIconSize {
    final w = (widget.width != null && widget.width!.isFinite)
        ? widget.width!
        : 48.0;
    final h = (widget.height != null && widget.height!.isFinite)
        ? widget.height!
        : 48.0;
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
      // Use 2x the layout size for crisp Retina display.
      return (layoutDimension * 2).ceil();
    }
    if (requestedSize != null && requestedSize > 0) {
      return requestedSize;
    }
    return null;
  }

  /// Resolves a pixel size from layout constraints only (no explicit size).
  /// Called only when no size or locked hero size was provided to the widget.
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
    final explicitWidth = _finitePositive(widget.width);
    final explicitHeight = _finitePositive(widget.height);
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
