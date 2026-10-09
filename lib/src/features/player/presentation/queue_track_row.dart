import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart'
    show songByIdProvider, subsonicApiProvider;
import 'package:navis/src/theme/artwork_shape.dart';

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

/// Prompts for a name and saves [queueIds] as a playlist.
void showQueueSaveAsPlaylistDialog(
  BuildContext context,
  WidgetRef ref,
  List<String> queueIds,
) {
  final l10n = AppLocalizations.of(context)!;
  final controller = TextEditingController();

  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.queueSaveAsPlaylist),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: l10n.queueSaveAsPlaylistName),
        onSubmitted: (_) => _saveQueuePlaylist(
          dialogContext,
          context,
          ref,
          controller.text.trim(),
          queueIds,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.cancelAction),
        ),
        FilledButton(
          onPressed: () => _saveQueuePlaylist(
            dialogContext,
            context,
            ref,
            controller.text.trim(),
            queueIds,
          ),
          child: Text(l10n.queueSaveAsPlaylist),
        ),
      ],
    ),
  );
}

void _saveQueuePlaylist(
  BuildContext dialogContext,
  BuildContext parentContext,
  WidgetRef ref,
  String name,
  List<String> queueIds,
) {
  if (name.isEmpty) {
    return;
  }
  Navigator.of(dialogContext).pop();
  final api = ref.read(subsonicApiProvider);
  if (api == null) {
    return;
  }
  final l10n = AppLocalizations.of(parentContext)!;
  unawaited(
    api.createPlaylist(name, songIds: queueIds).then((_) {
      if (parentContext.mounted) {
        showAppNotice(
          parentContext,
          message: l10n.queueSaveAsPlaylistSaved,
          level: AppNoticeLevel.success,
        );
      }
    }),
  );
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
  final VoidCallback onRemove;
  final VoidCallback onTap;
  final bool compact;
  final bool sheetDragActive;
  final ValueChanged<bool>? onSwipeActiveChanged;

  @override
  ConsumerState<QueueTrackRow> createState() => _QueueTrackRowState();
}

class _QueueTrackRowState extends ConsumerState<QueueTrackRow> {
  bool _isSwiping = false;

  void _onDismissUpdate(DismissUpdateDetails details) {
    final swiping = details.progress > 0.0;
    if (swiping == _isSwiping) return;
    _isSwiping = swiping;
    widget.onSwipeActiveChanged?.call(swiping);
  }

  @override
  void deactivate() {
    // Release lock when item is removed from the tree mid-swipe.
    if (_isSwiping) {
      _isSwiping = false;
      widget.onSwipeActiveChanged?.call(false);
    }
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
        IconButton(
          tooltip: l10n.commonRemove,
          onPressed: widget.actionsDisabled ? null : widget.onRemove,
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
          // No blunt threshold; intent is detected via onUpdate.
          onUpdate: _onDismissUpdate,
          background: Container(
            color: Theme.of(context).colorScheme.errorContainer,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 16),
            child: Icon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
          confirmDismiss: (_) async {
            widget.onRemove();
            return false;
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
          onPressed: widget.actionsDisabled ? null : widget.onRemove,
          icon: const Icon(Icons.delete_outline),
        ),
      ),
    );
  }
}
