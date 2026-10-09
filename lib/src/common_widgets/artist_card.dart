import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/star_button.dart';
import 'package:navis/src/database/navis_database.dart';
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
  });

  final ArtistsTableData artist;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<Offset>? onMorePressed;
  final GestureTapDownCallback? onSecondaryTapDown;
  final VoidCallback? onStarToggled;

  @override
  Widget build(BuildContext context) {
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
