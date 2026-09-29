import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/common_widgets/song_context_menu.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/library/domain/toggle_song_star.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/format_utils.dart';

/// Consistent trailing actions for a local song row in Desktop View.
///
/// Wide windows expose Like and Download directly; compact Desktop View keeps
/// metadata readable and retains the complete action set in More. Remote rows
/// intentionally have no local-server actions.
class DesktopSongActions extends ConsumerWidget {
  DesktopSongActions({
    required SongsTableData song,
    super.key,
    this.includeDuration = false,
    this.onMore,
    this.keyPrefix = 'desktop-song',
  }) : song = song,
       songId = song.id,
       isExternal = song.isExternal,
       duration = song.duration;

  const DesktopSongActions.forSongId({
    required this.songId,
    required this.isExternal,
    required this.onMore,
    super.key,
    this.duration,
    this.includeDuration = false,
    this.keyPrefix = 'desktop-song',
  }) : song = null;

  static const double directActionMinWidth = 1100;

  final SongsTableData? song;
  final String songId;
  final bool isExternal;
  final int? duration;
  final bool includeDuration;
  final FutureOr<void> Function(Offset? anchor)? onMore;
  final String keyPrefix;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rowMode = TrackRowModeScope.maybeOf(context);
    if (isExternal) {
      return includeDuration
          ? Text(
              formatSeconds(duration),
              style: Theme.of(context).textTheme.bodySmall,
            )
          : SizedBox(
              width: rowMode == null
                  ? 0
                  : rowMode == TrackRowMode.wide
                  ? 144
                  : 48,
            );
    }

    final l10n = AppLocalizations.of(context)!;
    final showDirectActions = rowMode != null
        ? rowMode == TrackRowMode.wide
        : MediaQuery.sizeOf(context).width >= directActionMinWidth;
    final isLiked =
        ref.watch(songStarredProvider(songId)).asData?.value ?? false;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (includeDuration) ...<Widget>[
          Text(
            formatSeconds(duration),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(width: 6),
        ],
        if (showDirectActions) ...<Widget>[
          IconButton(
            key: ValueKey<String>('$keyPrefix-heart-$songId'),
            tooltip: isLiked ? l10n.actionLiked : l10n.actionLike,
            icon: Icon(isLiked ? Icons.favorite : Icons.favorite_border),
            onPressed: () {
              unawaited(
                toggleSongStar(songId, ref).catchError((_) {
                  if (context.mounted) {
                    showAppNotice(
                      context,
                      message: l10n.albumDetailStarFailure,
                      level: AppNoticeLevel.error,
                    );
                  }
                }),
              );
            },
          ),
          SizedBox(
            width: 48,
            height: 48,
            child: SongDownloadStatusIcon(
              songId: songId,
              onDownload: () => unawaited(_download(context, ref)),
            ),
          ),
        ],
        Builder(
          builder: (buttonContext) => IconButton(
            key: ValueKey<String>('$keyPrefix-menu-$songId'),
            tooltip: l10n.actionMore,
            icon: const Icon(Icons.more_horiz_rounded),
            onPressed: () {
              final renderBox = buttonContext.findRenderObject() as RenderBox?;
              final anchor = renderBox?.localToGlobal(
                renderBox.size.center(Offset.zero),
              );
              final action = onMore;
              if (action != null) {
                unawaited(Future<void>.sync(() => action(anchor)));
              } else if (song case final localSong?) {
                unawaited(
                  showSongContextMenu(context, ref, localSong, anchor: anchor),
                );
              }
            },
          ),
        ),
      ],
    );
  }

  Future<void> _download(BuildContext context, WidgetRef ref) async {
    final choice = await showDownloadQualitySheet(context);
    if (choice == null || !context.mounted) return;
    await ref
        .read(downloadServiceProvider)
        .enqueueSong(songId, quality: choice.quality, format: choice.format);
    if (!context.mounted) return;
    showAppNotice(
      context,
      message: AppLocalizations.of(context)!.downloadSongQueued,
      level: AppNoticeLevel.success,
    );
  }
}
