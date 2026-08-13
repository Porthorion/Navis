import 'dart:async';

import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/theme/motion_policy.dart';

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
            if (flightDirection == HeroFlightDirection.push) {
              _HeroChromeRegistry.hide(heroTag);
            }
            if (flightDirection == HeroFlightDirection.pop) {
              void revealChromeAfterFlight(AnimationStatus status) {
                if (status != AnimationStatus.completed &&
                    status != AnimationStatus.dismissed) {
                  return;
                }
                animation.removeStatusListener(revealChromeAfterFlight);
                _HeroChromeRegistry.reveal(heroTag);
              }

              animation.addStatusListener(revealChromeAfterFlight);
            }

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
                useRequestedMemCacheSize: true,
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
        // A Hero must hand off to the destination's already-painted image.
        // A cached-network fade at either end briefly makes that image
        // translucent after the overlay disappears, which looks like flicker.
        fadeInDuration: fadeInDuration ?? Duration.zero,
        loadPriority: loadPriority,
        useRequestedMemCacheSize: true,
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

abstract interface class _HeroChromeHandle {
  void hideForHeroFlight();

  void revealAfterHeroFlight();
}

/// Connects the Hero flight to source-card chrome without relying on navigator
/// nesting or the route transition implementation.
abstract final class _HeroChromeRegistry {
  static final Map<String, _HeroChromeHandle> _handles =
      <String, _HeroChromeHandle>{};

  static void register(String tag, _HeroChromeHandle handle) {
    _handles[tag] = handle;
  }

  static void unregister(String tag, _HeroChromeHandle handle) {
    if (identical(_handles[tag], handle)) {
      _handles.remove(tag);
    }
  }

  static void hide(String tag) {
    _afterFrame(tag, (handle) => handle.hideForHeroFlight());
  }

  static void reveal(String tag) {
    _afterFrame(tag, (handle) => handle.revealAfterHeroFlight());
  }

  static void _afterFrame(
    String tag,
    void Function(_HeroChromeHandle handle) action,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final handle = _handles[tag];
      if (handle != null) {
        action(handle);
      }
    });
  }
}

/// Fades source-card metadata after its matching Hero has landed on return.
class HeroRouteChrome extends StatefulWidget {
  const HeroRouteChrome({
    this.heroTag,
    required this.child,
    super.key,
  });

  final String? heroTag;
  final Widget child;

  @override
  State<HeroRouteChrome> createState() => _HeroRouteChromeState();
}

class _HeroRouteChromeState extends State<HeroRouteChrome>
    with SingleTickerProviderStateMixin
    implements _HeroChromeHandle {
  late final AnimationController _returnFadeController;
  String? _registeredTag;

  @override
  void initState() {
    super.initState();
    _returnFadeController = AnimationController(
      vsync: this,
      duration: Duration.zero,
      value: 1,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _returnFadeController.duration = MotionPolicy.of(context).feedback;
    _syncRegistration();
  }

  @override
  void didUpdateWidget(covariant HeroRouteChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncRegistration();
  }

  void _syncRegistration() {
    final tag = widget.heroTag?.trim();
    final normalizedTag = tag == null || tag.isEmpty ? null : tag;
    if (_registeredTag == normalizedTag) {
      return;
    }
    if (_registeredTag != null) {
      _HeroChromeRegistry.unregister(_registeredTag!, this);
    }
    _registeredTag = normalizedTag;
    if (_registeredTag != null) {
      _HeroChromeRegistry.register(_registeredTag!, this);
    }
    _returnFadeController.value = 1;
  }

  @override
  void hideForHeroFlight() {
    _returnFadeController.stop();
    _returnFadeController.value = 0;
  }

  @override
  void revealAfterHeroFlight() {
    unawaited(_returnFadeController.forward(from: 0));
  }

  @override
  Widget build(BuildContext context) {
    if (_registeredTag == null) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: _returnFadeController,
      child: widget.child,
      builder: (context, child) {
        final opacity = Curves.easeOutCubic.transform(
          _returnFadeController.value,
        );
        return Opacity(opacity: opacity, child: child);
      },
    );
  }

  @override
  void dispose() {
    if (_registeredTag != null) {
      _HeroChromeRegistry.unregister(_registeredTag!, this);
    }
    _returnFadeController.dispose();
    super.dispose();
  }
}
