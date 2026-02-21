import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/star_button.dart';
import 'package:navis/src/database/navis_database.dart';

class AlbumCard extends StatelessWidget {
  const AlbumCard({
    required this.album,
    super.key,
    this.onTap,
    this.onLongPress,
  });

  final AlbumsTableData album;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final year = album.year == null ? '' : ' • ${album.year}';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        leading: AspectRatio(
          aspectRatio: 1,
          child: CoverArtImage(
            coverArtId: album.coverArt,
            size: 160,
            borderRadius: const BorderRadius.all(Radius.circular(6)),
            placeholderIcon: Icons.album_outlined,
          ),
        ),
        title: Text(album.name),
        subtitle: Text(
          '${album.artistName ?? l10n.albumDetailUnknownArtist}$year',
        ),
        trailing: album.starred == null
            ? null
            : StarButton(
                isStarred: true,
                compact: true,
                onPressed: null,
                tooltip: l10n.albumDetailStarAction,
              ),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}
