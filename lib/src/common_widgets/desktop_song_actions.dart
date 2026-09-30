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
import 'package:navis/src/theme/motion_policy.dart';
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
    final hasDownloadState =
        ref.watch(songDownloadStateProvider(songId)).status !=
        SongDownloadStatus.none;
    final rowEmphasized = TrackRowEmphasisScope.maybeOf(context) ?? true;

    return _QuietUntilEmphasized(
      rowEmphasized: rowEmphasized,
      child: Row(
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
            _ActionEmphasis(
              keep: isLiked,
              child: IconButton(
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
            ),
            _ActionEmphasis(
              keep: hasDownloadState,
              child: SizedBox(
                width: 48,
                height: 48,
                child: SongDownloadStatusIcon(
                  songId: songId,
                  onDownload: () => unawaited(_download(context, ref)),
                ),
              ),
            ),
          ],
          _ActionEmphasis(
            keep: false,
            child: Builder(
              builder: (buttonContext) => IconButton(
                key: ValueKey<String>('$keyPrefix-menu-$songId'),
                tooltip: l10n.actionMore,
                icon: const Icon(Icons.more_horiz_rounded),
                onPressed: () {
                  final renderBox =
                      buttonContext.findRenderObject() as RenderBox?;
                  final anchor = renderBox?.localToGlobal(
                    renderBox.size.center(Offset.zero),
                  );
                  final action = onMore;
                  if (action != null) {
                    unawaited(Future<void>.sync(() => action(anchor)));
                  } else if (song case final localSong?) {
                    unawaited(
                      showSongContextMenu(
                        context,
                        ref,
                        localSong,
                        anchor: anchor,
                      ),
                    );
                  }
                },
              ),
            ),
          ),
        ],
      ),
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

/// Tracks keyboard focus inside the actions so a focused control is never
/// dimmed, then tells [_ActionEmphasis] children whether to stay quiet.
class _QuietUntilEmphasized extends StatefulWidget {
  const _QuietUntilEmphasized({
    required this.rowEmphasized,
    required this.child,
  });

  final bool rowEmphasized;
  final Widget child;

  @override
  State<_QuietUntilEmphasized> createState() => _QuietUntilEmphasizedState();
}

class _QuietUntilEmphasizedState extends State<_QuietUntilEmphasized> {
  bool _focusWithin = false;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (value) => setState(() => _focusWithin = value),
    child: _ActionEmphasisScope(
      emphasized: widget.rowEmphasized || _focusWithin,
      child: widget.child,
    ),
  );
}

class _ActionEmphasisScope extends InheritedWidget {
  const _ActionEmphasisScope({required this.emphasized, required super.child});

  final bool emphasized;

  @override
  bool updateShouldNotify(_ActionEmphasisScope oldWidget) =>
      oldWidget.emphasized != emphasized;
}

/// Dims a row action until its row is emphasized, unless [keep] marks it as
/// showing meaningful state (liked, downloaded or downloading).
class _ActionEmphasis extends StatelessWidget {
  const _ActionEmphasis({required this.keep, required this.child});

  static const double _quietOpacity = 0.35;

  final bool keep;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final emphasized =
        context
            .dependOnInheritedWidgetOfExactType<_ActionEmphasisScope>()
            ?.emphasized ??
        true;
    final motion = MotionPolicy.of(context);
    return AnimatedOpacity(
      opacity: keep || emphasized ? 1 : _quietOpacity,
      duration: motion.reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 120),
      child: child,
    );
  }
}
