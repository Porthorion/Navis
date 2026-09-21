import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/utils/format_utils.dart';

class TrackListTile extends ConsumerWidget {
  const TrackListTile({
    required this.song,
    super.key,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.trailing,
    this.badge,
    this.showAlbumArt = false,
    this.horizontalTitleGap,
    this.contentPadding,
  });

  final SongsTableData song;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final GestureTapDownCallback? onSecondaryTapDown;
  final Widget? trailing;
  final Widget? badge;

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final playbackState = ref.watch(
      songPlaybackIndicatorStateProvider(song.id),
    );
    final isSelected = playbackState.isSelected;
    final hasArtist = song.artistName != null && song.artistName!.isNotEmpty;
    final hasAlbum = song.albumName != null && song.albumName!.isNotEmpty;

    final inactiveLeading = showAlbumArt
        ? SizedBox(
            width: 48,
            height: 48,
            child: CoverArtImage(
              coverArtId: song.coverArt,
              revision: song.coverArtRevision ?? 0,
              size: 80,
              borderRadius: BorderRadius.circular(6),
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
        ? ArtworkPlaybackMarker(
            state: playbackState,
            child: inactiveLeading!,
          )
        : isSelected
        ? SizedBox(
            width: 32,
            child: Center(
              child: SongPlaybackMarker(state: playbackState),
            ),
          )
        : inactiveLeading;

    // Build a RichText subtitle: "Artist · Album" with differentiated styling.
    Widget? subtitleWidget;
    if (hasArtist || hasAlbum || song.isExternal || badge != null) {
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

      final metadata = RichText(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(children: subtitleChildren),
      );
      subtitleWidget = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (subtitleChildren.isNotEmpty || song.isExternal)
            RemoteSourceMetadataLine(
              metadata: metadata,
              isRemote: song.isExternal,
              spacing: subtitleChildren.isEmpty ? 0 : 6,
            ),
          if (badge != null) ...<Widget>[
            if (subtitleChildren.isNotEmpty || song.isExternal)
              const SizedBox(height: 2),
            Wrap(
              spacing: 6,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[badge!],
            ),
          ],
        ],
      );
    }

    final tile = ListTile(
      dense: true,
      minTileHeight: 64,
      contentPadding: contentPadding,
      minLeadingWidth: showAlbumArt ? 48 : 32,
      horizontalTitleGap: horizontalTitleGap ?? 12,
      leading: leading,
      selected: isSelected,
      selectedColor: cs.primary,
      selectedTileColor: cs.primary.withValues(alpha: 0.08),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: isSelected ? cs.primary : null,
        ),
      ),
      subtitle: subtitleWidget,
      trailing:
          trailing ??
          Text(
            formatSeconds(song.duration),
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
    final interactiveTile = onSecondaryTapDown == null
        ? tile
        : GestureDetector(
            behavior: HitTestBehavior.translucent,
            onSecondaryTapDown: onSecondaryTapDown,
            child: tile,
          );
    return SongPlaybackSemantics(state: playbackState, child: interactiveTile);
  }
}
