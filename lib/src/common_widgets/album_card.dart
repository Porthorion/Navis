import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';

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
                                  style: TextStyle(
                                    color: artistColor,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
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
