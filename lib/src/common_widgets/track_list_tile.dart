import 'package:flutter/material.dart';
import 'package:navis/src/database/navis_database.dart';

class TrackListTile extends StatelessWidget {
  const TrackListTile({
    required this.song,
    super.key,
    this.onTap,
    this.onLongPress,
    this.trailing,
    this.badge,
  });

  final SongsTableData song;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final subtitle = <String>[
      if (song.artistName != null && song.artistName!.isNotEmpty)
        song.artistName!,
      if (song.albumName != null && song.albumName!.isNotEmpty) song.albumName!,
    ].join(' • ');

    return ListTile(
      leading: song.track == null ? null : Text('${song.track}'),
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
      onLongPress: onLongPress,
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
