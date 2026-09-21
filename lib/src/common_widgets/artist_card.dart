import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/star_button.dart';
import 'package:navis/src/database/navis_database.dart';

class ArtistCard extends StatelessWidget {
  const ArtistCard({
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
    final tile = ListTile(
      leading: CoverArtImage(
        coverArtId: artist.coverArt,
        revision: artist.coverArtRevision ?? 0,
        size: 96,
        width: 40,
        height: 40,
        circular: true,
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
                tooltip: MaterialLocalizations.of(
                  buttonContext,
                ).showMenuTooltip,
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
      onTap: onTap,
      onLongPress: onLongPress == null
          ? null
          : () {
              HapticFeedback.mediumImpact();
              onLongPress!();
            },
    );
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
