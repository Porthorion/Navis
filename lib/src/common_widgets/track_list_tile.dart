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
    final subtitle = <String>[
      if (song.artistName != null && song.artistName!.isNotEmpty)
        song.artistName!,
      if (song.albumName != null && song.albumName!.isNotEmpty) song.albumName!,
    ].join(' • ');

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
        : (song.track == null ? null : Text('${song.track}'));

    return ListTile(
      leading: leading,
      title: Text(song.title),
      subtitle: subtitle.isEmpty && badge == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (subtitle.isNotEmpty) Text(subtitle),
                if (badge != null) ...[
                  const SizedBox(height: 2),
                  badge!,
                ],
              ],
            ),
      trailing: trailing ?? Text(_formatDuration(song.duration)),
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
