import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_scope.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/features/player/presentation/queue_current_row_centering.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/queue_track_row.dart';
import 'package:navis/src/features/player/presentation/queue_shuffle_controls.dart';
import 'package:navis/src/features/player/presentation/queue_unavailable_tracks.dart';
import 'package:navis/src/providers/app_providers.dart'
    show playerStateProvider;
import 'package:navis/src/routing/navigation_service.dart';
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
    final actionsDisabled = queueActionsDisabled(playerSnapshot);
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
              : QueueCurrentRowCentering(
                  currentIndex: queueCurrentIndex(playerSnapshot, queueIds),
                  child: ReorderableListView.builder(
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
                      await reorderQueueItem(ref, oldIndex, newIndex);
                    },
                    itemBuilder: (context, index) {
                      return QueueTrackRow(
                        key: queueRowKey(queueIds, index),
                        songId: queueIds[index],
                        index: index,
                        compact: true,
                        indicatorState: queueRowIndicatorState(
                          playerSnapshot,
                          queueIds,
                          index,
                        ),
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
                      showQueueSaveAsPlaylistDialog(context, ref, queueIds),
                ),
              if (queueIds.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.clear_all),
                  tooltip: l10n.queueClearAction,
                  onPressed: actionsDisabled
                      ? null
                      : () => confirmAndClearQueue(context, ref),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}
