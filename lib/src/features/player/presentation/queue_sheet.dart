import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_scope.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/queue_shuffle_controls.dart';
import 'package:navis/src/features/player/presentation/queue_unavailable_tracks.dart';
import 'package:navis/src/providers/app_providers.dart'
    show playerStateProvider, songByIdProvider, subsonicApiProvider;
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/artwork_shape.dart';
import 'package:navis/src/theme/navis_shape_data.dart';

/// A queue panel. Slide animation and swipe-to-dismiss are driven entirely
/// by the shell overlay in `app_shell.dart`; this widget has no animation
/// logic of its own.
///
/// [scrollController] must be supplied by the overlay so that the overlay's
/// pointer listener can check the scroll offset when deciding whether a
/// downward drag should move the sheet or scroll the list.
class QueueSheet extends ConsumerWidget {
  const new({
    required this.scrollController,
    this.sheetDragActive = false,
    this.onReorderDragChanged,
    this.onItemSwipeActiveChanged,
    this.onClose,
    this.embeddedMode = false,
    super.key,
  });

  final ScrollController scrollController;
  final bool sheetDragActive;
  final ValueChanged<bool>? onReorderDragChanged;
  final ValueChanged<bool>? onItemSwipeActiveChanged;
  final VoidCallback? onClose;
  final bool embeddedMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final queueIds = ref.watch(queueProvider);
    final retained = ref.watch(retainedArtistQueueProvider);
    final playerSnapshot = ref.watch(playerStateProvider);
    final actionsDisabled =
        playerSnapshot.isLoading && playerSnapshot.hasPendingLogicalQueue;
    final close = onClose ?? () => Navigator.of(context).pop();

    final body = Column(
      children: <Widget>[
        _QueueSheetHeader(
          queueIds: queueIds,
          actionsDisabled: actionsDisabled,
          onClose: close,
          // The _CompactWideOverlaySheet already draws a drag pill at the
          // top of the panel, so suppress the header's own pill in embedded
          // mode to avoid showing two pills.
          showDragPill: !embeddedMode,
        ),
        Expanded(
          child: queueIds.isEmpty && retained.isEmpty
              ? EmptyState(
                  title: l10n.queueEmptyTitle,
                  subtitle: l10n.queueEmptySubtitle,
                  icon: Icons.queue_music_outlined,
                )
              : ReorderableListView.builder(
                  footer: const QueueUnavailableTracks(),
                  scrollController: scrollController,
                  physics: sheetDragActive
                      ? const NeverScrollableScrollPhysics()
                      : const ClampingScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: queueIds.length,
                  onReorderStart: (_) => onReorderDragChanged?.call(true),
                  onReorderEnd: (_) => onReorderDragChanged?.call(false),
                  onReorderItem: (oldIndex, newIndex) async {
                    if (actionsDisabled) return;
                    // The handler retains the insertion index before removal.
                    await ref.read(reorderQueueProvider)(
                      oldIndex,
                      oldIndex < newIndex ? newIndex + 1 : newIndex,
                    );
                  },
                  itemBuilder: (context, index) {
                    final songId = queueIds[index];
                    final indicatorState =
                        resolveQueueSongPlaybackIndicatorState(
                          rowIndex: index,
                          rowSongId: songId,
                          queueSongIds: queueIds,
                          currentIndex: playerSnapshot.currentIndex,
                          currentSongId: playerSnapshot.currentSongId,
                          isLoading: playerSnapshot.isLoading,
                          loadingSongId: playerSnapshot.loadingSongId,
                        );

                    return _QueueItem(
                      key: queueRowKey(queueIds, index),
                      songId: songId,
                      index: index,
                      indicatorState: indicatorState,
                      actionsDisabled: actionsDisabled,
                      sheetDragActive: sheetDragActive,
                      onSwipeActiveChanged: onItemSwipeActiveChanged,
                      onRemove: () {
                        if (actionsDisabled) return;
                        ref
                            .read(queueProvider.notifier)
                            .fireAndForget(
                              () => ref
                                  .read(queueProvider.notifier)
                                  .removeAt(index),
                              label: 'remove queue item',
                            );
                      },
                      onTap: () async {
                        if (actionsDisabled) return;
                        await ref
                            .read(queueProvider.notifier)
                            .playFromIndex(index);
                      },
                    );
                  },
                ),
        ),
      ],
    );

    if (embeddedMode) {
      return Material(
        color: nowPlayingArtworkPanelFill(
          context,
          Theme.of(context).colorScheme.surface,
        ),
        child: body,
      );
    }

    return SafeArea(
      top: true,
      bottom: false,
      child: Material(
        color: nowPlayingArtworkPanelFill(
          context,
          Theme.of(context).colorScheme.surface,
        ),
        elevation: 12,
        shape: RoundedRectangleBorder(
          borderRadius: NavisShapeData.of(context).sheetTop,
        ),
        clipBehavior: Clip.antiAlias,
        child: body,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

class _QueueSheetHeader extends ConsumerWidget {
  const new({
    required this.queueIds,
    required this.actionsDisabled,
    required this.onClose,
    this.showDragPill = true,
  });

  final List<String> queueIds;
  final bool actionsDisabled;
  final VoidCallback onClose;
  final bool showDragPill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // Drag handle indicator — hidden when embedded inside a panel that
        // already shows its own pill (e.g. _CompactWideOverlaySheet).
        if (showDragPill)
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Container(
                width: 22,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: <Widget>[
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                icon: const Icon(Icons.close),
                onPressed: () {
                  NavService.dismissKeyboard(context);
                  onClose();
                },
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  l10n.queueTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (queueIds.isNotEmpty) const QueueShuffleToggle(),
              if (queueIds.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.playlist_add),
                  tooltip: l10n.queueSaveAsPlaylist,
                  onPressed: () =>
                      _showSaveAsPlaylistDialog(context, ref, queueIds),
                ),
              if (queueIds.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.clear_all),
                  tooltip: l10n.queueClearAction,
                  onPressed: actionsDisabled
                      ? null
                      : () async {
                          final confirmed = await showDialog<bool?>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text(l10n.queueClearConfirmTitle),
                              content: Text(l10n.queueClearConfirmMessage),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(false),
                                  child: Text(l10n.cancelAction),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.of(ctx).pop(true),
                                  child: Text(l10n.queueClearAction),
                                ),
                              ],
                            ),
                          );

                          if ((confirmed ?? false) && context.mounted) {
                            await ref.read(queueProvider.notifier).clear();
                          }
                        },
                ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }

  void _showSaveAsPlaylistDialog(
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
          onSubmitted: (_) => _savePlaylist(
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
            onPressed: () => _savePlaylist(
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

  void _savePlaylist(
    BuildContext dialogContext,
    BuildContext parentContext,
    WidgetRef ref,
    String name,
    List<String> queueIds,
  ) {
    if (name.isEmpty) return;
    Navigator.of(dialogContext).pop();
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;
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
}

// ---------------------------------------------------------------------------
// Queue item
// ---------------------------------------------------------------------------

class _QueueItem extends ConsumerStatefulWidget {
  const new({
    required super.key,
    required this.songId,
    required this.index,
    required this.indicatorState,
    required this.actionsDisabled,
    required this.onRemove,
    required this.onTap,
    this.sheetDragActive = false,
    this.onSwipeActiveChanged,
  });

  final String songId;
  final int index;
  final SongPlaybackIndicatorState indicatorState;
  final bool actionsDisabled;
  final VoidCallback onRemove;
  final VoidCallback onTap;
  final bool sheetDragActive;
  final ValueChanged<bool>? onSwipeActiveChanged;

  @override
  ConsumerState<_QueueItem> createState() => _QueueItemState();
}

class _QueueItemState extends ConsumerState<_QueueItem> {
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
          // No blunt threshold — intent is detected via onUpdate.
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
              trailing: Row(
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
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant
                                  .withValues(alpha: 0.38),
                            )
                          : ReorderableDragStartListener(
                              index: widget.index,
                              child: Icon(
                                Icons.drag_indicator_rounded,
                                size: 18,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
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
