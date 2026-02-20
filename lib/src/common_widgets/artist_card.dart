import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/database/navis_database.dart';

class ArtistCard extends StatelessWidget {
  const ArtistCard({
    required this.artist,
    super.key,
    this.onTap,
    this.onLongPress,
  });

  final ArtistsTableData artist;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

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
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}
