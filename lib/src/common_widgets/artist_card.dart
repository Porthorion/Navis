import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/star_button.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/navis_density_scope.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:navis/src/theme/artwork_shape.dart';

class ArtistCard extends StatelessWidget {
  const new({
    required this.artist,
    super.key,
    this.onTap,
    this.onLongPress,
    this.onMorePressed,
    this.onSecondaryTapDown,
    this.onStarToggled,
  }) : grid = false;

  /// Grid variant: avatar with the artist name centered below, for a
  /// `SliverGrid`. Has no "more" or star actions.
  const new grid({
    required this.artist,
    super.key,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
  }) : grid = true,
       onMorePressed = null,
       onStarToggled = null;

  final bool grid;

  final ArtistsTableData artist;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<Offset>? onMorePressed;
  final GestureTapDownCallback? onSecondaryTapDown;
  final VoidCallback? onStarToggled;

  @override
  Widget build(BuildContext context) {
    if (grid) {
      return _ArtistGridTile(
        artist: artist,
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTapDown: onSecondaryTapDown,
      );
    }
    final l10n = AppLocalizations.of(context)!;
    final albumCount = artist.albumCount ?? 0;
    final density = NavisDensityScope.of(context);
    final tile = ListTile(
      dense: density.compact,
      visualDensity: density.compact ? VisualDensity.compact : null,
      leading: CoverArtImage(
        coverArtId: artist.coverArt,
        revision: artist.coverArtRevision ?? 0,
        size: 96,
        width: density.compact ? 36 : 40,
        height: density.compact ? 36 : 40,
        shape: ArtworkShapeRole.artist,
        placeholderIcon: Icons.person_outline,
        isExternalSource: artist.isExternal,
      ),
      title: Text(artist.name),
      subtitle: Text(l10n.artistCardAlbumCount(albumCount)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (onMorePressed != null)
            Builder(
              builder: (buttonContext) => IconButton(
                icon: const Icon(Icons.more_horiz),
                tooltip: MaterialLocalizations.of(buttonContext)
                    .showMenuTooltip,
                onPressed: () {
                  final renderObject = buttonContext.findRenderObject();
                  if (renderObject is! RenderBox) return;
                  onMorePressed!(
                    renderObject.localToGlobal(
                      renderObject.size.center(Offset.zero),
                    ),
                  );
                },
              ),
            ),
          StarButton(
            isStarred: artist.starred != null,
            compact: true,
            onPressed: onStarToggled,
            tooltip: l10n.albumDetailStarAction,
          ),
        ],
      ),
      shape: NavisShapeData.of(context).mdShape,
      onTap: onTap,
      onLongPress: onLongPress == null
          ? null
          : () {
              unawaited(HapticFeedback.mediumImpact());
              onLongPress!();
            },
    );
    // Flat rows, like track lists: a card per artist added 12 px of chrome
    // to every row without grouping anything.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: NavisSpace.sm),
      child: onSecondaryTapDown == null
          ? tile
          : GestureDetector(
              behavior: HitTestBehavior.translucent,
              onSecondaryTapDown: onSecondaryTapDown,
              child: tile,
            ),
    );
  }
}

/// A grid-friendly artist card with a configurable shape avatar and the artist
/// name centered below. Suitable for use inside a `SliverGrid`.
class _ArtistGridTile extends ConsumerWidget {
  const new({
    required this.artist,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
  });

  final ArtistsTableData artist;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final GestureTapDownCallback? onSecondaryTapDown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shape = ref.watch(artistCardShapeProvider);
    final borderRadius = artworkBorderRadius(shape, extent: double.infinity);

    return InkWell(
      borderRadius: NavisShapeData.of(context).mdAll,
      onTap: onTap,
      onSecondaryTapDown: onSecondaryTapDown,
      onLongPress: onLongPress == null
          ? null
          : () {
              unawaited(HapticFeedback.mediumImpact());
              onLongPress!();
            },
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final side = constraints.maxWidth < constraints.maxHeight
                      ? constraints.maxWidth
                      : constraints.maxHeight;
                  return Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: side,
                      height: side,
                      child: CoverArtImage(
                        coverArtId: artist.coverArt,
                        revision: artist.coverArtRevision ?? 0,
                        size: kCoverArtStandardSize,
                        width: side,
                        height: side,
                        borderRadius: borderRadius,
                        placeholderIcon: Icons.person_outline,
                        isExternalSource: artist.isExternal,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            Text(
              artist.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
