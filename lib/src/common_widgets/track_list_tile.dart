import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/theme/artwork_shape.dart';

class TrackListTile extends ConsumerWidget {
  const new({
    required this.song,
    super.key,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.trailing,
    this.badge,
    this.showAlbumArt = false,
    this.showAlbumColumn = true,
    this.horizontalTitleGap,
    this.contentPadding,
    this.actionExtent,
  });

  final SongsTableData song;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final GestureTapDownCallback? onSecondaryTapDown;
  final Widget? trailing;
  final Widget? badge;
  final double? actionExtent;

  /// Override the gap between the leading widget and the title.
  /// Defaults to 12 when null.
  final double? horizontalTitleGap;

  /// Override the tile padding.
  /// Defaults to the Material [ListTile] padding when null.
  final EdgeInsetsGeometry? contentPadding;

  /// When true, show the album art as the leading widget instead of a track
  /// number. Useful in contexts where the track number is meaningless (e.g.,
  /// the Liked songs list which spans many albums).
  final bool showAlbumArt;

  /// See [AdaptiveTrackRow.showAlbumColumn].
  final bool showAlbumColumn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playbackState = ref.watch(
      songPlaybackIndicatorStateProvider(song.id),
    );
    final isSelected = playbackState.isSelected;

    final inactiveLeading = showAlbumArt
        ? SizedBox(
            width: 48,
            height: 48,
            child: CoverArtImage(
              coverArtId: song.coverArt,
              revision: song.coverArtRevision ?? 0,
              size: 80,
              width: 48,
              height: 48,
              shape: ArtworkShapeRole.cover,
              isExternalSource: song.isExternal,
              remoteSourceIndicatorPolicy: RemoteSourceIndicatorPolicy.hidden,
            ),
          )
        : (song.track == null
              ? null
              : SizedBox(
                  width: 32,
                  child: Center(
                    child: Text(
                      '${song.track}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ));
    final leading = showAlbumArt
        ? ArtworkPlaybackMarker(state: playbackState, child: inactiveLeading!)
        : isSelected
        ? SizedBox(
            width: 32,
            child: Center(child: SongPlaybackMarker(state: playbackState)),
          )
        : inactiveLeading;

    final interactiveTile = AdaptiveTrackRow(
      title: song.title,
      artist: song.artistName,
      album: song.albumName,
      showAlbumColumn: showAlbumColumn,
      duration: song.duration,
      leading: leading,
      leadingExtent: showAlbumArt ? 48 : 32,
      leadingGap: horizontalTitleGap ?? 12,
      actionExtent: actionExtent,
      selected: isSelected,
      isRemote: song.isExternal,
      actions: trailing,
      badge: badge,
      onTap: onTap,
      padding:
          contentPadding ??
          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      onLongPress: onLongPress == null
          ? null
          : () {
              unawaited(HapticFeedback.mediumImpact());
              onLongPress!();
            },
      onSecondaryTapDown: onSecondaryTapDown,
    );
    return SongPlaybackSemantics(state: playbackState, child: interactiveTile);
  }
}
