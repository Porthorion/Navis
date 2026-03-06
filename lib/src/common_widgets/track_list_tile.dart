import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/database/navis_database.dart';

class TrackListTile extends StatelessWidget {
  const TrackListTile({
    required this.song,
    super.key,
    this.onTap,
    this.onLongPress,
    this.trailing,
    this.badge,
    this.showAlbumArt = false,
  });

  final SongsTableData song;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final Widget? badge;

  /// When true, show the album art as the leading widget instead of a track
  /// number. Useful in contexts where the track number is meaningless (e.g.,
  /// the Liked songs list which spans many albums).
  final bool showAlbumArt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final hasArtist = song.artistName != null && song.artistName!.isNotEmpty;
    final hasAlbum = song.albumName != null && song.albumName!.isNotEmpty;

    final leading = showAlbumArt
        ? SizedBox(
            width: 48,
            height: 48,
            child: CoverArtImage(
              coverArtId: song.coverArt,
              size: 80,
              borderRadius: BorderRadius.circular(6),
            ),
          )
        : (song.track == null
              ? null
              : SizedBox(
                  width: 32,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${song.track}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ));

    // Build a RichText subtitle: "Artist · Album" with differentiated styling.
    Widget? subtitleWidget;
    if (hasArtist || hasAlbum || badge != null) {
      final subtitleChildren = <InlineSpan>[];
      if (hasArtist) {
        subtitleChildren.add(
          TextSpan(
            text: song.artistName,
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.8),
            ),
          ),
        );
      }
      if (hasArtist && hasAlbum) {
        subtitleChildren.add(
          TextSpan(
            text: ' · ',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.4),
            ),
          ),
        );
      }
      if (hasAlbum) {
        subtitleChildren.add(
          TextSpan(
            text: song.albumName,
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
        );
      }

      subtitleWidget = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (subtitleChildren.isNotEmpty)
            RichText(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              text: TextSpan(children: subtitleChildren),
            ),
          if (badge != null) ...[
            const SizedBox(height: 2),
            badge!,
          ],
        ],
      );
    }

    return ListTile(
      dense: true,
      minLeadingWidth: showAlbumArt ? 48 : 32,
      horizontalTitleGap: 12,
      leading: leading,
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: subtitleWidget,
      trailing:
          trailing ??
          Text(
            _formatDuration(song.duration),
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
      onTap: onTap,
      onLongPress: onLongPress == null
          ? null
          : () {
              HapticFeedback.mediumImpact();
              onLongPress!();
            },
    );
  }
}

String _formatDuration(int? seconds) {
  if (seconds == null || seconds <= 0) {
    return '--:--';
  }
  final minutes = seconds ~/ 60;
  final remainder = seconds % 60;
  return '$minutes:${remainder.toString().padLeft(2, '0')}';
}
