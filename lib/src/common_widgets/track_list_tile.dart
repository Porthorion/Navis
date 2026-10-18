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
import 'package:navis/src/theme/navis_density_scope.dart';

class TrackListTile extends ConsumerWidget {
  const new({
    required this.song,
    super.key,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.trailing,
    this.badge,
    this.showAlbumArt = true,
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

  /// Shows the album art as the leading widget; false shows the track number
  /// instead, which only means something inside one album.
  final bool showAlbumArt;

  /// See [AdaptiveTrackRow.showAlbumColumn].
  final bool showAlbumColumn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playbackState = ref.watch(
      songPlaybackIndicatorStateProvider(song.id),
    );
    final isSelected = playbackState.isSelected;
    final cover = NavisDensityScope.of(context).listCover;

    final inactiveLeading = showAlbumArt
        ? SizedBox(
            width: cover,
            height: cover,
            child: CoverArtImage(
              coverArtId: song.coverArt,
              revision: song.coverArtRevision ?? 0,
              size: 80,
              width: cover,
              height: cover,
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
      leadingExtent: showAlbumArt ? cover : 32,
      leadingGap: horizontalTitleGap ?? 12,
      actionExtent: actionExtent,
      selected: isSelected,
      isRemote: song.isExternal,
      actions: trailing,
      badge: badge,
      onTap: onTap,
      padding: contentPadding,
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
