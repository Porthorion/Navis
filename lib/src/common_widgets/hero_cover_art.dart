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

/// Fades card metadata while a Hero-enabled detail route is on top.
///
/// The artwork itself is owned by the Navigator's Hero overlay. Without this
/// companion fade, the source card's separately composed title/artist gradient
/// can reappear in one frame when the Hero returns on pop.
class HeroRouteChrome extends StatefulWidget {
  const HeroRouteChrome({
    required this.enabled,
    required this.child,
    super.key,
  });

  final bool enabled;
  final Widget child;

  @override
  State<HeroRouteChrome> createState() => _HeroRouteChromeState();
}

class _HeroRouteChromeState extends State<HeroRouteChrome>
    with SingleTickerProviderStateMixin {
  static const Duration _returnFadeDuration = Duration(milliseconds: 120);

  late final AnimationController _returnFadeController = AnimationController(
    vsync: this,
    duration: _returnFadeDuration,
    value: 1,
  );
  Animation<double>? _secondaryAnimation;
  bool _wasCovered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final secondaryAnimation = ModalRoute.of(context)?.secondaryAnimation;
    if (_secondaryAnimation == secondaryAnimation) {
      return;
    }
    _secondaryAnimation?.removeListener(_handleSecondaryTick);
    _secondaryAnimation = secondaryAnimation;
    _secondaryAnimation?.addListener(_handleSecondaryTick);
    _handleSecondaryTick();
  }

  @override
  void didUpdateWidget(covariant HeroRouteChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled) {
      _returnFadeController.value = 1;
    }
  }

  void _handleSecondaryTick() {
    final secondaryAnimation = _secondaryAnimation;
    if (secondaryAnimation == null) {
      return;
    }
    if (secondaryAnimation.value > 0) {
      _wasCovered = true;
      if (_returnFadeController.value != 0) {
        _returnFadeController.value = 0;
      }
      return;
    }
    if (_wasCovered) {
      _wasCovered = false;
      _returnFadeController.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || _secondaryAnimation == null) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: _returnFadeController,
      child: widget.child,
      builder: (context, child) {
        // The Hero is complete only once the source route's secondary
        // animation is dismissed. Keep the overlay hidden until then, then
        // reveal it with a separate fade so it never competes with the art.
        final opacity = Curves.easeOutCubic.transform(
          _returnFadeController.value,
        );
        return Opacity(opacity: opacity, child: child);
      },
    );
  }

  @override
  void dispose() {
    _secondaryAnimation?.removeListener(_handleSecondaryTick);
    _returnFadeController.dispose();
    super.dispose();
  }
}
