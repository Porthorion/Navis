import 'dart:async';

import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/navis_haptics.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart'
    show QueueBatchEditor;
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart'
    show audioHandlerProvider, songByIdProvider;
import 'package:navis/src/routing/desktop_layout.dart'
    show resolveAdaptiveContextFor;
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/theme/artwork_shape.dart';
import 'package:navis/src/features/settings/domain/haptics_prefs.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Queue edits are blocked while a logical queue replacement is still loading.
bool queueActionsDisabled(PlaybackSnapshot playback) =>
    playback.isLoading && playback.hasPendingLogicalQueue;

/// Indicator state for the queue row at [index] of [queueIds].
SongPlaybackIndicatorState queueRowIndicatorState(
  PlaybackSnapshot playback,
  List<String> queueIds,
  int index,
) => resolveQueueSongPlaybackIndicatorState(
  rowIndex: index,
  rowSongId: queueIds[index],
  queueSongIds: queueIds,
  currentIndex: playback.currentIndex,
  currentSongId: playback.currentSongId,
  isLoading: playback.isLoading,
  loadingSongId: playback.loadingSongId,
);

/// Applies a reorder drop; the handler retains the insertion index before
/// removal.
Future<void> reorderQueueItem(WidgetRef ref, int oldIndex, int newIndex) async {
  await ref.read(reorderQueueProvider)(
    oldIndex,
    oldIndex < newIndex ? newIndex + 1 : newIndex,
  );
}

/// Asks for confirmation, then clears the queue.
Future<void> confirmAndClearQueue(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showDialog<bool?>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.queueClearConfirmTitle),
      content: Text(l10n.queueClearConfirmMessage),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.cancelAction),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.queueClearAction),
        ),
      ],
    ),
  );

  if ((confirmed ?? false) && context.mounted) {
    await ref.read(queueProvider.notifier).clear();
  }
}

/// Removes the queue row at [index] and offers a 5 s Undo notice.
///
/// Everything the Undo needs is read before the first await, and the action
/// holds only the [QueueController] and the notice controller (never [ref] or
/// [context]), so it still works after the Queue sheet has closed. Returns
/// whether the song was removed.
Future<bool> removeQueueRowWithUndo(
  BuildContext context,
  WidgetRef ref,
  int index,
  String songId,
) async {
  final queue = ref.read(queueProvider.notifier);
  final notices = AppNoticeScope.maybeOf(context);
  final l10n = AppLocalizations.of(context)!;
  final title =
      ref.read(songByIdProvider(songId)).asData?.value?.title ??
      l10n.queueUnknownTrack;
  final undoable = ref.read(audioHandlerProvider) is QueueBatchEditor;
  final removal = await queue.removeForUndo(index, songId);
  if (removal == null) return false;
  notices?.show(
    message: l10n.queueRemovedNotice(title),
    duration: const Duration(seconds: 5),
    // The last remaining row has no neighbour to anchor an Undo.
    actionLabel: undoable && !removal.wasOnly ? l10n.commonUndo : null,
    onAction: () => unawaited(queue.undoRemoval(removal)),
  );
  return true;
}

/// One queue row shared by the full Queue screen and the Queue sheet.
///
/// [compact] selects the sheet's trailing controls (remove button plus a small
/// drag indicator); otherwise the screen's plain drag handle is used.
class QueueTrackRow extends ConsumerStatefulWidget {
  const new({
    required super.key,
    required this.songId,
    required this.index,
    required this.indicatorState,
    required this.actionsDisabled,
    required this.onRemove,
    required this.onTap,
    this.compact = false,
    this.sheetDragActive = false,
    this.onSwipeActiveChanged,
  });

  final String songId;
  final int index;
  final SongPlaybackIndicatorState indicatorState;
  final bool actionsDisabled;

  /// Removes this row; completes once the queue shows the change. Resolves
  /// false when nothing was removed.
  final Future<bool> Function() onRemove;
  final VoidCallback onTap;
  final bool compact;
  final bool sheetDragActive;
  final ValueChanged<bool>? onSwipeActiveChanged;

  @override
  ConsumerState<QueueTrackRow> createState() => _QueueTrackRowState();
}

class _QueueTrackRowState extends ConsumerState<QueueTrackRow> {
  bool _isSwiping = false;

  bool _committed = false;

  /// The swipe is past the commit point (red background, filled icon).
  bool _reached = false;

  /// Hidden from the moment the row is committed until the queue answers.
  bool _removing = false;

  void _releaseSwipeLock() {
    if (!_isSwiping) return;
    _isSwiping = false;
    widget.onSwipeActiveChanged?.call(false);
  }

  /// Swipe, semantics action and desktop button all remove through here.
  Future<void> _commitRemoval() async {
    if (_removing) return;
    setState(() => _removing = true);
    _releaseSwipeLock();
    try {
      await widget.onRemove();
      // A refused removal answers before any frame, but a dismissed
      // Dismissible must leave the tree for one built frame before the row
      // may come back; without this wait the row would reappear under it.
      await WidgetsBinding.instance.endOfFrame;
    } on Object catch (error) {
      // Handler failures were reported by runReportingErrors; log the rest
      // (notice/l10n). The row comes back below.
      AppLogger.warning('Queue row removal failed: $error');
    } finally {
      // Removed rows are gone from the list by now; a refused or failed
      // removal brings the row back.
      _committed = false;
      _reached = false;
      if (mounted) setState(() => _removing = false);
    }
  }

  void _onDismissUpdate(DismissUpdateDetails details) {
    // The click sits exactly where letting go removes the track. After the
    // commit the row slides out (or springs back if the removal is refused),
    // which is not a pull back, so it stays quiet until the row is at rest.
    if (_committed) {
      if (details.progress == 0) _committed = false;
    } else if (details.reached != details.previousReached) {
      setState(() => _reached = details.reached);
      if (details.reached) {
        NavisHaptics.thresholdOn(HapticCategory.listsAndMenus);
      } else {
        NavisHaptics.thresholdOff(HapticCategory.listsAndMenus);
      }
    }
    final swiping = details.progress > 0.0;
    if (swiping == _isSwiping) return;
    _isSwiping = swiping;
    widget.onSwipeActiveChanged?.call(swiping);
  }

  @override
  void deactivate() {
    // Release lock when item is removed from the tree mid-swipe.
    _releaseSwipeLock();
    super.deactivate();
  }

  Widget _trailing(BuildContext context, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    if (!widget.compact) {
      return widget.actionsDisabled
          ? Icon(
              Icons.drag_handle,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.38),
            )
          : ReorderableDragStartListener(
              index: widget.index,
              child: Icon(Icons.drag_handle, color: scheme.onSurfaceVariant),
            );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // Phones remove by swipe or the screen-reader action; the button stays
        // where there is a pointer.
        if (resolveAdaptiveContextFor(context).desktopRuntime)
          IconButton(
            tooltip: l10n.commonRemove,
            onPressed: widget.actionsDisabled
                ? null
                : () => unawaited(_commitRemoval()),
            icon: const Icon(Icons.delete_outline),
          ),
        SizedBox(
          width: 28,
          child: Center(
            child: widget.actionsDisabled
                ? Icon(
                    Icons.drag_indicator_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.38),
                  )
                : ReorderableDragStartListener(
                    index: widget.index,
                    child: Icon(
                      Icons.drag_indicator_rounded,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final songAsync = ref.watch(songByIdProvider(widget.songId));
    final isSelected = widget.indicatorState.isSelected;
    if (_removing) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion = MotionPolicy.of(context).reduceMotion;
    const slide = Duration(milliseconds: 200);

    return songAsync.when(
      data: (song) {
        if (song == null) {
          return ListTile(
            key: widget.key,
            title: Text(l10n.queueUnknownTrack),
            subtitle: Text(l10n.queueUnavailableTrackDescription),
          );
        }

        return Dismissible(
          key: widget.key!,
          // Lock dismiss when the sheet is being dragged vertically.
          direction: widget.sheetDragActive || widget.actionsDisabled
              ? DismissDirection.none
              : DismissDirection.endToStart,
          dismissThresholds: const {DismissDirection.endToStart: 0.45},
          movementDuration: reduceMotion ? Duration.zero : slide,
          resizeDuration: reduceMotion ? null : slide,
          onUpdate: _onDismissUpdate,
          background: AnimatedContainer(
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 150),
            color: _reached
                ? scheme.errorContainer
                : scheme.surfaceContainerHighest,
            alignment: AlignmentDirectional.centerEnd,
            padding: const EdgeInsetsDirectional.only(end: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Flexible(
                  child: Text(
                    l10n.queueSwipeRemoveLabel,
                    maxLines: 2,
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: _reached
                          ? scheme.onErrorContainer
                          : scheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  _reached ? Icons.delete : Icons.delete_outline,
                  color: _reached ? scheme.onErrorContainer : scheme.onSurface,
                ),
              ],
            ),
          ),
          confirmDismiss: (_) async {
            _committed = true;
            NavisHaptics.reject(HapticCategory.listsAndMenus);
            return true;
          },
          onDismissed: (_) => unawaited(_commitRemoval()),
          child: Semantics(
            customSemanticsActions: widget.actionsDisabled
                ? const <CustomSemanticsAction, VoidCallback>{}
                : <CustomSemanticsAction, VoidCallback>{
                    CustomSemanticsAction(
                      label: l10n.queueSwipeRemoveLabel,
                    ): () =>
                        unawaited(_commitRemoval()),
                  },
            child: SongPlaybackSemantics(
              state: widget.indicatorState,
              child: ListTile(
                selected: isSelected,
                selectedColor: Theme.of(context).colorScheme.primary,
                selectedTileColor: Theme.of(context).colorScheme.primary
                    .withValues(alpha: 0.08),
                leading: ArtworkPlaybackMarker(
                  state: widget.indicatorState,
                  child: CoverArtImage(
                    coverArtId: song.coverArt,
                    revision: song.coverArtRevision ?? 0,
                    size: kCoverArtStandardSize,
                    width: 48,
                    height: 48,
                    shape: ArtworkShapeRole.cover,
                    isExternalSource: song.isExternal,
                    remoteSourceIndicatorPolicy:
                        RemoteSourceIndicatorPolicy.hidden,
                  ),
                ),
                title: Text(
                  song.title,
                  style: isSelected
                      ? TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        )
                      : null,
                ),
                subtitle: RemoteSourceMetadataLine(
                  metadata: Text(
                    song.artistName ?? l10n.queueUnknownArtist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isRemote: song.isExternal,
                  spacing: 8,
                ),
                trailing: _trailing(context, l10n),
                enabled: !widget.actionsDisabled,
                onTap: widget.actionsDisabled ? null : widget.onTap,
              ),
            ),
          ),
        );
      },
      loading: () => ListTile(
        key: widget.key,
        leading: const SizedBox(
          width: 48,
          height: 48,
          child: Center(child: CircularProgressIndicator()),
        ),
        title: Text(l10n.commonLoading),
      ),
      error: (error, _) => ListTile(
        key: widget.key,
        title: Text(l10n.queueTrackLoadError),
        subtitle: Text(l10n.queueTrackLoadErrorDescription),
        trailing: IconButton(
          tooltip: l10n.commonRemove,
          onPressed: widget.actionsDisabled
              ? null
              : () => unawaited(widget.onRemove()),
          icon: const Icon(Icons.delete_outline),
        ),
      ),
    );
  }
}
