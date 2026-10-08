import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/album_card_caption_variant.dart';
import 'package:navis/src/common_widgets/album_context_menu.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/features/home/presentation/cover_colour_field.dart';
import 'package:navis/src/theme/caption_tint.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/artwork_shape.dart';

/// Size presets for [AlbumCard].
enum AlbumCardSize {
  /// Compact cards used in home carousels (150 × 150).
  compact(150),

  /// Larger cards used in the library grid – sized to fill available width.
  library(double.infinity);

  new(this.extent);
  final double extent;
}

/// A modern square album card.
///
/// Album art fills the entire card.  The title and artist name are overlaid
/// at the bottom where the artwork fades into the active app surface.
class AlbumCard extends ConsumerWidget {
  const new({
    required this.album,
    super.key,
    this.size = AlbumCardSize.library,
    this.heroTag,
    this.extent,
    this.badge,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
  });

  final AlbumsTableData album;
  final AlbumCardSize size;
  final double? extent;

  /// Optional hero tag for cover-art transition animations.
  final String? heroTag;
  final Widget? badge;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final GestureTapDownCallback? onSecondaryTapDown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shape = ref.watch(coverArtShapeProvider);
    final cardBorderRadius = artworkBorderRadius(
      shape,
      extent: double.infinity,
    );
    final cardWidth = extent ?? size.extent;

    final titleMaxLines = size == AlbumCardSize.library ? 2 : 1;
    return AlbumCardCaptionLayout(
      width: cardWidth,
      title: album.name,
      subtitle: album.artistName ?? '',
      titleMaxLines: titleMaxLines,
      card: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: cardBorderRadius),
        child: InkWell(
          key: const ValueKey('albumCardTapTarget'),
          onTap: onTap,
          onSecondaryTapDown: onSecondaryTapDown,
          onLongPress: onLongPress == null
              ? null
              : () {
                  unawaited(HapticFeedback.mediumImpact());
                  onLongPress!();
                },
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (heroTag != null)
                HeroCoverArt(
                  coverArtId: album.coverArt,
                  revision: album.coverArtRevision ?? 0,
                  heroTag: heroTag!,
                  size: kCoverArtStandardSize,
                  fit: BoxFit.cover,
                  placeholderIcon: Icons.album_outlined,
                  borderRadius: cardBorderRadius,
                  isExternalSource: album.isExternal,
                )
              else
                CoverArtImage(
                  coverArtId: album.coverArt,
                  revision: album.coverArtRevision ?? 0,
                  size: kCoverArtStandardSize,
                  fit: BoxFit.cover,
                  placeholderIcon: Icons.album_outlined,
                  isExternalSource: album.isExternal,
                ),
              HeroRouteChrome(
                heroTag: heroTag,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    if (badge != null)
                      Positioned(top: 8, right: 8, child: badge!),
                    AlbumCardLabel(
                      title: album.name,
                      subtitle: album.artistName ?? '',
                      titleMaxLines: titleMaxLines,
                      coverArtId: album.coverArt,
                    ),
                    if (onTap != null && isDesktopRuntime)
                      Positioned.fill(
                        child: _AlbumCardHoverPlay(albumId: album.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const double _captionTopGap = 6;
const double _captionLineGap = 2;
const double _captionFadeHeight = 24;
const double _tintFadeMidAlpha = 0.85;

TextStyle _titleStyle(Color color) =>
    TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600);

TextStyle? _subtitleStyle(ThemeData theme, Color color) => theme
    .textTheme
    .labelSmall
    ?.copyWith(color: color, fontWeight: FontWeight.w400);

/// The height the `below` caption needs under a cover: top gap, up to
/// [titleMaxLines] title lines and one subtitle line, at the ambient text
/// scale. Grids and rails add it to their cover extent while the `below`
/// variant is active (see [albumCardExtraHeight]).
double albumCardCaptionHeight(BuildContext context, int titleMaxLines) {
  final theme = Theme.of(context);
  final base = DefaultTextStyle.of(context).style;
  final scaler = MediaQuery.textScalerOf(context);
  final direction = Directionality.of(context);
  double measure(TextStyle style, int lines) {
    final painter = TextPainter(
      text: TextSpan(text: List.filled(lines, 'Ag').join('\n'), style: style),
      textDirection: direction,
      textScaler: scaler,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  final title = measure(base.merge(_titleStyle(Colors.black)), titleMaxLines);
  final subtitle = measure(base.merge(_subtitleStyle(theme, Colors.black)), 1);
  // A little slack for rounding so the caption never overflows its box.
  return (_captionTopGap + title + _captionLineGap + subtitle + 1)
      .ceilToDouble();
}

/// Extra card height a grid or rail must reserve under the cover for the
/// active caption variant: zero except for `below`.
double albumCardExtraHeight(
  BuildContext context,
  WidgetRef ref, {
  int titleMaxLines = 1,
}) =>
    ref.watch(albumCardCaptionVariantProvider) == AlbumCardCaptionVariant.below
    ? albumCardCaptionHeight(context, titleMaxLines)
    : 0;

/// Lays out a cover [card] with its caption for the active
/// [AlbumCardCaptionVariant]. Shared by [AlbumCard] and `ExternalAlbumCard`.
///
/// Every variant but `below` keeps the card a square of [width]; `below`
/// stacks the caption under the square cover, so the widget is taller by
/// [albumCardCaptionHeight].
class AlbumCardCaptionLayout extends ConsumerWidget {
  const new({
    required this.width,
    required this.card,
    required this.title,
    required this.subtitle,
    this.titleMaxLines = 1,
    super.key,
  });

  final double? width;
  final Widget card;
  final String title;
  final String subtitle;
  final int titleMaxLines;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final below =
        ref.watch(albumCardCaptionVariantProvider) ==
        AlbumCardCaptionVariant.below;
    if (!below) {
      return SizedBox(
        width: width,
        child: AspectRatio(aspectRatio: 1, child: card),
      );
    }
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AspectRatio(aspectRatio: 1, child: card),
          SizedBox(
            key: const ValueKey<String>('albumCardCaptionBelow'),
            height: albumCardCaptionHeight(context, titleMaxLines),
            child: Padding(
              padding: const EdgeInsets.only(
                top: _captionTopGap,
                left: 2,
                right: 2,
              ),
              child: _CaptionTexts(
                title: title,
                subtitle: subtitle,
                titleMaxLines: titleMaxLines,
                titleColor: colors.onSurface,
                subtitleColor: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptionTexts extends StatelessWidget {
  const new({
    required this.title,
    required this.subtitle,
    required this.titleMaxLines,
    required this.titleColor,
    required this.subtitleColor,
  });

  final String title;
  final String subtitle;
  final int titleMaxLines;
  final Color titleColor;
  final Color subtitleColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          title,
          maxLines: titleMaxLines,
          overflow: TextOverflow.ellipsis,
          style: _titleStyle(titleColor),
        ),
        const SizedBox(height: _captionLineGap),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _subtitleStyle(theme, subtitleColor),
        ),
      ],
    );
  }
}

/// The title and subtitle at the bottom of an album card, drawn over the
/// cover for the `overlayFade` and `coverTint` caption variants (see
/// [AlbumCardCaptionVariant]); it draws nothing for `below`, where
/// [AlbumCardCaptionLayout] places the caption under the cover. Shared by
/// [AlbumCard] and `ExternalAlbumCard`; place it directly in the card's
/// [Stack].
class AlbumCardLabel extends ConsumerWidget {
  const new({
    required this.title,
    required this.subtitle,
    this.titleMaxLines = 1,
    this.coverArtId,
    super.key,
  });

  final String title;
  final String subtitle;

  final int titleMaxLines;

  /// Cover whose colours tint the `coverTint` caption; null falls back to the
  /// `overlayFade` look.
  final String? coverArtId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final variant = ref.watch(albumCardCaptionVariantProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final surface = theme.scaffoldBackgroundColor;
    switch (variant) {
      case AlbumCardCaptionVariant.below:
        return const SizedBox.shrink();
      case AlbumCardCaptionVariant.overlayFade:
        // The title sits on a fade of the page background, not on the
        // artwork, so it uses the scheme's text colours in every theme.
        return Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _OverlayFadeLabel(
            tint: CaptionTint(
              fill: surface,
              text: colorScheme.onSurface,
              subtext: colorScheme.onSurfaceVariant,
            ),
            title: title,
            subtitle: subtitle,
            titleMaxLines: titleMaxLines,
          ),
        );
      case AlbumCardCaptionVariant.coverTint:
        return Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _CoverTintLabel(
            coverArtId: coverArtId,
            title: title,
            subtitle: subtitle,
            titleMaxLines: titleMaxLines,
          ),
        );
    }
  }
}

/// The `coverTint` caption: a fade into a colour sampled from the cover's
/// bottom edge, with text chosen and the fill nudged for 4.5:1 contrast (see
/// [captionTintFor]). Until the colours are known, or for a cover without
/// art, it shows the `overlayFade` look.
class _CoverTintLabel extends ConsumerWidget {
  const new({
    required this.coverArtId,
    required this.title,
    required this.subtitle,
    required this.titleMaxLines,
  });

  final String? coverArtId;
  final String title;
  final String subtitle;
  final int titleMaxLines;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final id = coverArtId;
    // Only a built card samples; the cache hit avoids a fallback flash.
    final field = id == null || id.isEmpty
        ? null
        : ref.watch(coverColourFieldProvider(id)).value ??
              peekCoverColourField(id);
    final fallback = CaptionTint(
      fill: theme.scaffoldBackgroundColor,
      text: colorScheme.onSurface,
      subtext: colorScheme.onSurfaceVariant,
    );
    if (field == null) {
      return _OverlayFadeLabel(
        tint: fallback,
        title: title,
        subtitle: subtitle,
        titleMaxLines: titleMaxLines,
      );
    }
    final target = captionTintFor(
      field.bottomRowAverage,
      NavisColorStyleData.of(context),
    );
    return TweenAnimationBuilder<CaptionTint>(
      key: const ValueKey<String>('albumCardCoverTint'),
      tween: _CaptionTintTween(begin: fallback, end: target),
      duration: MotionPolicy.of(context).tint,
      builder: (context, tint, _) => _OverlayFadeLabel(
        tint: tint,
        stagedFade: true,
        title: title,
        subtitle: subtitle,
        titleMaxLines: titleMaxLines,
      ),
    );
  }
}

class _CaptionTintTween extends Tween<CaptionTint> {
  new({required super.begin, required super.end});

  @override
  CaptionTint lerp(double t) => CaptionTint.lerp(begin!, end!, t);
}

/// A caption fading from transparent into [CaptionTint.fill]. With
/// [stagedFade] the fade reaches 85% opacity where the text starts and is
/// solid behind it; otherwise it is the plain `overlayFade` gradient.
class _OverlayFadeLabel extends StatelessWidget {
  const new({
    required this.tint,
    required this.title,
    required this.subtitle,
    required this.titleMaxLines,
    this.stagedFade = false,
  });

  final CaptionTint tint;
  final bool stagedFade;
  final String title;
  final String subtitle;
  final int titleMaxLines;

  @override
  Widget build(BuildContext context) {
    final fill = tint.fill;
    final texts = _CaptionTexts(
      title: title,
      subtitle: subtitle,
      titleMaxLines: titleMaxLines,
      titleColor: tint.text,
      subtitleColor: tint.subtext,
    );
    LinearGradient gradient(Color from, Color to) => LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: <Color>[from, to],
    );
    return stagedFade
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DecoratedBox(
                key: const ValueKey<String>('albumCardTintFade'),
                decoration: BoxDecoration(
                  gradient: gradient(
                    fill.withValues(alpha: 0),
                    fill.withValues(alpha: _tintFadeMidAlpha),
                  ),
                ),
                child: const SizedBox(
                  height: _captionFadeHeight,
                  width: double.infinity,
                ),
              ),
              DecoratedBox(
                key: const ValueKey<String>('albumCardTintText'),
                decoration: BoxDecoration(
                  gradient: gradient(
                    fill.withValues(alpha: _tintFadeMidAlpha),
                    fill,
                  ),
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                    child: texts,
                  ),
                ),
              ),
            ],
          )
        : DecoratedBox(
            key: const ValueKey<String>('albumCardTitleSurfaceFade'),
            decoration: BoxDecoration(
              gradient: gradient(fill.withValues(alpha: 0), fill),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                10,
                _captionFadeHeight,
                10,
                10,
              ),
              child: texts,
            ),
          );
  }
}

/// Desktop quick-play button that appears while the pointer is over a card.
///
/// It stays out of the focus order and hit testing while hidden; keyboard
/// users play albums from the card's context menu or detail page.
class _AlbumCardHoverPlay extends ConsumerStatefulWidget {
  const new({required this.albumId});

  final String albumId;

  @override
  ConsumerState<_AlbumCardHoverPlay> createState() =>
      _AlbumCardHoverPlayState();
}

class _AlbumCardHoverPlayState extends ConsumerState<_AlbumCardHoverPlay> {
  bool _hovered = false;

  /// The button is only built while hovered or fading out; a grid shows
  /// dozens of cards, and an invisible button still costs build work.
  bool _buttonMounted = false;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() {
      _hovered = value;
      if (value) _buttonMounted = true;
    });
  }

  void _handleFadeEnd() {
    if (!_hovered && _buttonMounted) setState(() => _buttonMounted = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final motion = MotionPolicy.of(context);
    return MouseRegion(
      opaque: false,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: Center(
        child: IgnorePointer(
          ignoring: !_hovered,
          child: ExcludeFocus(
            excluding: !_hovered,
            child: AnimatedOpacity(
              opacity: _hovered ? 1 : 0,
              duration: motion.reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 120),
              onEnd: _handleFadeEnd,
              child: !_buttonMounted
                  ? const SizedBox.square(dimension: 52)
                  // Announced to screen readers without a hover tooltip;
                  // the play glyph speaks for itself to pointer users.
                  : Semantics(
                      container: true,
                      button: true,
                      label: l10n.libraryAlbumMenuPlay,
                      excludeSemantics: true,
                      child: IconButton.filled(
                        key: const ValueKey<String>('albumCardHoverPlay'),
                        iconSize: 28,
                        constraints: const BoxConstraints(
                          minWidth: 52,
                          minHeight: 52,
                        ),
                        onPressed: () =>
                            unawaited(playAlbumById(ref, widget.albumId)),
                        icon: const Icon(Icons.play_arrow_rounded),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
