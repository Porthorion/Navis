import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/common_widgets/cover_art_source.dart';
import 'package:navis/src/features/home/presentation/cover_colour_field.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_background.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_scope.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart'
    show
        nowPlayingCachedTintColor,
        nowPlayingVisualCacheKeyFor,
        prewarmNowPlayingVisuals,
        resolveNowPlayingImageProvider;
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

/// The blurred cover a visible Artwork background is drawing, published so
/// surfaces outside the Now Playing subtree (the phone queue overlay) can
/// paint the same layer without a second decode or fetch.
@immutable
class NowPlayingPublishedBackdrop {
  const new({
    required this.owner,
    required this.imageKey,
    required this.image,
    required this.coverAverage,
    required this.useCoverAverage,
  });

  /// The [NowPlayingBackdrop] state that published this.
  final Object owner;
  final String? imageKey;
  final ImageProvider<Object> image;
  final Color? coverAverage;
  final bool useCoverAverage;

  @override
  bool operator ==(Object other) =>
      other is NowPlayingPublishedBackdrop &&
      other.owner == owner &&
      other.imageKey == imageKey &&
      other.image == image &&
      other.coverAverage == coverAverage &&
      other.useCoverAverage == useCoverAverage;

  @override
  int get hashCode =>
      Object.hash(owner, imageKey, image, coverAverage, useCoverAverage);
}

/// Holds the published Artwork backdrop, or null while Now Playing shows none.
class NowPlayingPublishedBackdropController
    extends Notifier<NowPlayingPublishedBackdrop?> {
  @override
  NowPlayingPublishedBackdrop? build() => null;

  /// Publishes an owned snapshot rather than exposing a writable property.
  // ignore: use_setters_to_change_properties
  void publish(NowPlayingPublishedBackdrop backdrop) => state = backdrop;

  /// Clears the backdrop if [owner] still owns it.
  void clear(Object owner) {
    if (!ref.mounted) return;
    if (state?.owner == owner) state = null;
  }
}

final nowPlayingPublishedBackdropProvider =
    NotifierProvider<
      NowPlayingPublishedBackdropController,
      NowPlayingPublishedBackdrop?
    >(NowPlayingPublishedBackdropController.new);

/// The Now Playing background: art-tinted surface, Artwork (blurred cover,
/// veil and [NowPlayingArtworkLayerScope]) or plain surface, following the
/// Now Playing Background setting, [NavisColorStyleData.flatNowPlaying] and
/// OLED rules.
///
/// Owns the tint lookup/prewarm and the backdrop image resolution, so the
/// Now Playing screen and the desktop lyrics view share one implementation.
/// With [publishToQueueOverlay] the visible Artwork layer is also published to
/// [nowPlayingPublishedBackdropProvider].
class NowPlayingBackdrop extends ConsumerStatefulWidget {
  const new({
    required this.hasActivePlayback,
    required this.coverArtId,
    required this.coverArtRevision,
    required this.artUrl,
    required this.child,
    this.publishToQueueOverlay = false,
    this.textAcrossCover = false,
    super.key,
  });

  final bool hasActivePlayback;

  /// Server cover id of the playing song; null for radio.
  final String? coverArtId;
  final int coverArtRevision;

  /// Art URL of the playing item (radio art or media-item art).
  final String? artUrl;
  final bool publishToQueueOverlay;

  /// Text runs across the whole cover (the desktop lyrics view), so the
  /// Artwork veil keeps a higher floor than on Now Playing, where text sits
  /// below the cover art.
  final bool textAcrossCover;
  final Widget child;

  @override
  ConsumerState<NowPlayingBackdrop> createState() => _NowPlayingBackdropState();
}

class _NowPlayingBackdropState extends ConsumerState<NowPlayingBackdrop> {
  /// Dominant color extracted from the current cover art for tinting.
  Color? _artTintColor;
  Color? _lastStableTintColor;

  /// The cover art ID that [_artTintColor] was extracted from.
  String? _extractedCoverArtId;

  /// Small cover for the Artwork background, memoised per cover identity.
  String? _artworkBackdropKey;
  ImageProvider<Object>? _artworkBackdropImage;
  final Set<String> _failedArtworkBackdropKeys = <String>{};

  NowPlayingPublishedBackdrop? _published;
  late final NowPlayingPublishedBackdropController _publisher;

  @override
  void initState() {
    super.initState();
    _publisher = ref.read(nowPlayingPublishedBackdropProvider.notifier);
  }

  @override
  void dispose() {
    // A pending post-frame clear may not have run before disposal.
    // Consumers outside this subtree may still be mounted during tree cleanup.
    WidgetsBinding.instance.addPostFrameCallback((_) => _publisher.clear(this));
    WidgetsBinding.instance.scheduleFrame();
    super.dispose();
  }

  /// Decodes the cached standard 600 px cover at a thumbnail width.
  ImageProvider<Object>? _artworkBackdropFor({
    required String? coverArtId,
    required String? artUrl,
    int revision = 0,
  }) {
    final trimmedId = coverArtId?.trim() ?? '';
    final trimmedUrl = artUrl?.trim() ?? '';
    // A transient metadata gap keeps the previous cover, like the tint does.
    if (trimmedId.isEmpty && trimmedUrl.isEmpty) return _artworkBackdropImage;
    ImageProvider<Object>? base;
    if (trimmedId.isNotEmpty) {
      final source = ref.watch(
        coverArtImageSourceProvider((
          trimmedId,
          kCoverArtStandardSize,
          revision,
        )),
      );
      // Keep the current layer mounted while the durable-store probe completes,
      // so it can crossfade once the next source has decoded.
      if (source.isLoading) return _artworkBackdropImage;
      base = source.asData?.value;
    } else {
      base = resolveNowPlayingImageProvider(
        ref: ref,
        artUrl: trimmedUrl,
        size: kCoverArtStandardSize,
      );
    }
    final key = trimmedId.isNotEmpty
        ? 'id:$trimmedId:$revision:${base?.hashCode}'
        : 'url:$trimmedUrl:${base?.hashCode}';
    if (key == _artworkBackdropKey && _artworkBackdropImage != null) {
      return _artworkBackdropImage;
    }
    _artworkBackdropKey = key;
    return _artworkBackdropImage = base == null
        ? null
        : ResizeImage(base, width: kNowPlayingArtworkDecodeWidth);
  }

  Future<void> _extractArtColor({String? coverArtId, String? artUrl}) async {
    final brightness = Theme.of(context).brightness;
    final cacheKey = nowPlayingVisualCacheKeyFor(
      brightness: brightness,
      coverArtId: coverArtId,
      artUrl: artUrl,
    );
    if (cacheKey == _extractedCoverArtId) return;
    _extractedCoverArtId = cacheKey;

    if (cacheKey == null) {
      // Keep the previous tint during transient metadata gaps so the surface
      // does not flash back to default between track transitions.
      return;
    }
    final cachedTint = nowPlayingCachedTintColor(
      brightness: brightness,
      coverArtId: coverArtId,
      artUrl: artUrl,
    );
    if (cachedTint != null) {
      if (mounted) setState(() => _artTintColor = cachedTint);
      return;
    }

    await prewarmNowPlayingVisuals(
      context: context,
      ref: ref,
      brightness: brightness,
      coverArtId: coverArtId,
      artUrl: artUrl,
    );
    final warmedTint = nowPlayingCachedTintColor(
      brightness: brightness,
      coverArtId: coverArtId,
      artUrl: artUrl,
    );
    if (mounted && _extractedCoverArtId == cacheKey && warmedTint != null) {
      setState(() => _artTintColor = warmedTint);
    }
  }

  void _publish(NowPlayingPublishedBackdrop? next) {
    if (!widget.publishToQueueOverlay && _published == null) return;
    if (next == _published) return;
    _published = next;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _published != next) return;
      if (next == null) {
        _publisher.clear(this);
      } else {
        _publisher.publish(next);
      }
    });
  }

  Widget _withArtworkBackground({
    required bool showArtworkLayer,
    required ImageProvider<Object>? image,
    required NavisColorStyleData colorStyle,
    required ColorScheme colors,
    required Duration fadeDuration,
    required Widget child,
  }) {
    if (!showArtworkLayer) {
      _publish(null);
      return child;
    }
    final id = widget.coverArtId?.trim();
    final hasCoverId = id != null && id.isNotEmpty;
    final average = hasCoverId
        ? (ref
                      .watch(
                        backgroundCoverColourFieldProvider((
                          id,
                          widget.coverArtRevision,
                        )),
                      )
                      .value ??
                  peekCoverColourField(id))
              ?.average
        : null;
    if (widget.publishToQueueOverlay) {
      _publish(
        NowPlayingPublishedBackdrop(
          owner: this,
          imageKey: _artworkBackdropKey,
          image: image!,
          coverAverage: average,
          useCoverAverage: hasCoverId,
        ),
      );
    } else {
      _publish(null);
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned.fill(
          child: NowPlayingArtworkBackground(
            key: const ValueKey<String>('nowPlayingArtworkBackground'),
            imageKey: _artworkBackdropKey,
            image: image,
            coverAverage: average,
            useCoverAverage: hasCoverId,
            onAvailabilityChanged: (key, {required available}) {
              if (!mounted || key != _artworkBackdropKey) return;
              setState(() {
                if (available) {
                  _failedArtworkBackdropKeys.remove(key);
                } else {
                  _failedArtworkBackdropKeys.add(key);
                }
              });
            },
            colorStyle: colorStyle,
            surfaceColor: colors.surface,
            onSurfaceColor: colors.onSurface,
            accentColor: colors.primary,
            onSurfaceVariantColor: colors.onSurfaceVariant,
            minVeilAlpha: widget.textAcrossCover
                ? nowPlayingTextAcrossCoverVeilFloor(colorStyle)
                : null,
            fadeDuration: fadeDuration,
          ),
        ),
        NowPlayingArtworkLayerScope(active: true, child: child),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final motion = MotionPolicy.of(context);
    final background = ref.watch(nowPlayingBackgroundProvider);
    final brightness = Theme.of(context).brightness;
    final colors = Theme.of(context).colorScheme;
    final colorStyle = NavisColorStyleData.of(context);
    final hasActivePlayback = widget.hasActivePlayback;
    final coverArtId = widget.coverArtId;
    final activeArtUrl = widget.artUrl;
    // Artwork draws a blurred cover; Flat has no blur, and a cover that
    // cannot load falls back to the tinted look, so both still need a tint.
    ImageProvider<Object>? artworkImage;
    if (background == NowPlayingBackground.artwork && hasActivePlayback) {
      artworkImage = _artworkBackdropFor(
        coverArtId: coverArtId,
        artUrl: activeArtUrl,
        revision: widget.coverArtRevision,
      );
    } else {
      _artworkBackdropKey = null;
      _artworkBackdropImage = null;
    }
    final showArtworkLayer = nowPlayingShowsArtworkLayer(
      background: background,
      flat: colorStyle.flatNowPlaying,
      hasImage:
          artworkImage != null &&
          !_failedArtworkBackdropKeys.contains(_artworkBackdropKey),
    );
    final artTinted =
        background == NowPlayingBackground.tinted ||
        (background == NowPlayingBackground.artwork && !showArtworkLayer);
    final cachedTintColor = artTinted
        ? nowPlayingCachedTintColor(
            brightness: brightness,
            coverArtId: coverArtId,
            artUrl: activeArtUrl,
          )
        : null;

    // Trigger color extraction when art-tinted mode is on.
    if (artTinted) {
      if (!hasActivePlayback) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              (_artTintColor != null || _lastStableTintColor != null)) {
            setState(() {
              _artTintColor = null;
              _lastStableTintColor = null;
            });
          }
        });
      } else if (cachedTintColor == null) {
        // Schedule after build to avoid setState during build.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final id = coverArtId?.trim() ?? '';
          final url = activeArtUrl?.trim() ?? '';
          if (id.isNotEmpty) {
            unawaited(_extractArtColor(coverArtId: id));
          } else if (url.isNotEmpty) {
            unawaited(_extractArtColor(artUrl: url));
          }
        });
      }
    } else if (_artTintColor != null || _lastStableTintColor != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            (_artTintColor != null || _lastStableTintColor != null)) {
          setState(() {
            _artTintColor = null;
            _lastStableTintColor = null;
          });
        }
      });
    }

    final surfaceColor = colors.surface;
    final extractedTintColor = cachedTintColor ?? _artTintColor;
    if (artTinted &&
        hasActivePlayback &&
        extractedTintColor != null &&
        extractedTintColor != _lastStableTintColor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _lastStableTintColor != extractedTintColor) {
          setState(() => _lastStableTintColor = extractedTintColor);
        }
      });
    }
    final tintColor = artTinted
        ? (extractedTintColor ??
              (hasActivePlayback ? _lastStableTintColor : null))
        : null;

    return Material(
      color: surfaceColor,
      child: AnimatedContainer(
        key: const ValueKey<String>('nowPlayingSurfaceTint'),
        duration: motion.surface,
        curve: Curves.easeInOutCubic,
        decoration: nowPlayingSurfaceDecoration(
          tintColor: tintColor,
          colorStyle: colorStyle,
          surfaceColor: surfaceColor,
        ),
        child: _withArtworkBackground(
          showArtworkLayer: showArtworkLayer,
          image: artworkImage,
          colorStyle: colorStyle,
          colors: colors,
          fadeDuration: motion.surface,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Veil floor for views with text across the whole cover: dark 0.6, OLED
/// 0.8, light 0.72.
double nowPlayingTextAcrossCoverVeilFloor(NavisColorStyleData style) =>
    !style.dark ? 0.72 : (style.oled ? 0.8 : 0.6);
