import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/album_context_menu.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/motion_policy.dart';

/// Size presets for [AlbumCard].
enum AlbumCardSize {
  /// Compact cards used in home carousels (150 × 150).
  compact(150),

  /// Larger cards used in the library grid – sized to fill available width.
  library(double.infinity);

  const AlbumCardSize(this.extent);
  final double extent;
}

/// A modern square album card.
///
/// Album art fills the entire card.  The title and artist name are overlaid
/// at the bottom where the artwork fades into the active app surface.
class AlbumCard extends ConsumerWidget {
  const AlbumCard({
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isLightTheme = theme.brightness == Brightness.light;
    final titleColor = isLightTheme ? colorScheme.onSurface : Colors.white;
    final artistColor = isLightTheme
        ? colorScheme.onSurfaceVariant
        : const Color(0xCCFFFFFF);
    final shape = ref.watch(coverArtShapeProvider);
    final cardBorderRadius = coverArtShapeToRadius(shape);
    final cardWidth = extent ?? size.extent;

    return SizedBox(
      width: cardWidth,
      child: AspectRatio(
        aspectRatio: 1,
        child: Card(
          clipBehavior: Clip.antiAlias,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: cardBorderRadius,
          ),
          child: InkWell(
            key: const ValueKey('albumCardTapTarget'),
            onTap: onTap,
            onSecondaryTapDown: onSecondaryTapDown,
            onLongPress: onLongPress == null
                ? null
                : () {
                    HapticFeedback.mediumImpact();
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
                        Positioned(
                          top: 8,
                          right: 8,
                          child: badge!,
                        ),
                      // Fade into the selected app surface so the labels use
                      // the same readable foreground roles as the rest of Navis.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: DecoratedBox(
                          key: const ValueKey<String>(
                            'albumCardTitleSurfaceFade',
                          ),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: <Color>[
                                theme.scaffoldBackgroundColor.withValues(
                                  alpha: 0,
                                ),
                                theme.scaffoldBackgroundColor,
                              ],
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(10, 24, 10, 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  album.name,
                                  maxLines: size == AlbumCardSize.library
                                      ? 2
                                      : 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: titleColor,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  album.artistName ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: artistColor,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
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
      ),
    );
  }
}

/// Desktop quick-play button that appears while the pointer is over a card.
///
/// It stays out of the focus order and hit testing while hidden; keyboard
/// users play albums from the card's context menu or detail page.
class _AlbumCardHoverPlay extends ConsumerStatefulWidget {
  const _AlbumCardHoverPlay({required this.albumId});

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
