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
    this.onStarToggled,
  });

  final ArtistsTableData artist;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onStarToggled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final albumCount = artist.albumCount ?? 0;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        leading: CoverArtImage(
          coverArtId: artist.coverArt,
          size: 96,
          width: 40,
          height: 40,
          circular: true,
          placeholderIcon: Icons.person_outline,
        ),
        title: Text(artist.name),
        subtitle: Text(l10n.artistCardAlbumCount(albumCount)),
        trailing: StarButton(
          isStarred: artist.starred != null,
          compact: true,
          onPressed: onStarToggled,
          tooltip: l10n.albumDetailStarAction,
        ),
        onTap: onTap,
        onLongPress: onLongPress == null
            ? null
            : () {
                HapticFeedback.mediumImpact();
                onLongPress!();
              },
      ),
    );
  }
}
