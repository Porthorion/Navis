import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/queue_unavailable_tracks.dart';
import 'package:navis/src/providers/app_providers.dart'
    show playerStateProvider, songByIdProvider, subsonicApiProvider;
import 'package:navis/src/theme/artwork_shape.dart';

class QueueScreen extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final queueIds = ref.watch(queueProvider);
    final retained = ref.watch(retainedArtistQueueProvider);
    final playback = ref.watch(playerStateProvider);
    // Same guard as QueueSheet: the logical queue is still being replaced.
    final actionsDisabled =
        playback.isLoading && playback.hasPendingLogicalQueue;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.queueTitle),
        actions: [
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
              onPressed: () async {
                final confirmed = await showDialog<bool?>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(l10n.queueClearConfirmTitle),
                    content: Text(l10n.queueClearConfirmMessage),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: Text(l10n.cancelAction),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(true),
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
      body: queueIds.isEmpty && retained.isEmpty
          ? EmptyState(
              title: l10n.queueEmptyTitle,
              subtitle: l10n.queueEmptySubtitle,
              icon: Icons.queue_music_outlined,
            )
          : ReorderableListView.builder(
              footer: const QueueUnavailableTracks(),
              padding: const EdgeInsets.only(bottom: 80),
              itemCount: queueIds.length,
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
                final indicatorState = resolveQueueSongPlaybackIndicatorState(
                  rowIndex: index,
                  rowSongId: songId,
                  queueSongIds: queueIds,
                  currentIndex: playback.currentIndex,
                  currentSongId: playback.currentSongId,
                  isLoading: playback.isLoading,
                  loadingSongId: playback.loadingSongId,
                );

                return _QueueItem(
                  key: queueRowKey(queueIds, index),
                  songId: songId,
                  index: index,
                  indicatorState: indicatorState,
                  actionsDisabled: actionsDisabled,
                  onRemove: () async {
                    if (actionsDisabled) return;
                    await ref.read(queueProvider.notifier).removeAt(index);
                  },
                  onTap: () async {
                    if (actionsDisabled) return;
                    await ref.read(queueProvider.notifier).playFromIndex(index);
                  },
                );
              },
            ),
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
}

class _QueueItem extends ConsumerWidget {
  const new({
    required super.key,
    required this.songId,
    required this.index,
    required this.indicatorState,
    required this.actionsDisabled,
    required this.onRemove,
    required this.onTap,
  });

  final String songId;
  final int index;
  final SongPlaybackIndicatorState indicatorState;
  final bool actionsDisabled;
  final VoidCallback onRemove;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final songAsync = ref.watch(songByIdProvider(songId));
    final isSelected = indicatorState.isSelected;

    return songAsync.when(
      data: (song) {
        if (song == null) {
          return ListTile(
            key: key,
            title: Text(l10n.queueUnknownTrack),
            subtitle: Text(l10n.queueUnavailableTrackDescription),
          );
        }

        return Dismissible(
          key: key!,
          direction: actionsDisabled
              ? DismissDirection.none
              : DismissDirection.endToStart,
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
            onRemove();
            return false;
          },
          child: SongPlaybackSemantics(
            state: indicatorState,
            child: ListTile(
              selected: isSelected,
              selectedColor: Theme.of(context).colorScheme.primary,
              selectedTileColor: Theme.of(context).colorScheme.primary
                  .withValues(alpha: 0.08),
              leading: ArtworkPlaybackMarker(
                state: indicatorState,
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
              trailing: actionsDisabled
                  ? Icon(
                      Icons.drag_handle,
                      color: Theme.of(context).colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.38),
                    )
                  : ReorderableDragStartListener(
                      index: index,
                      child: Icon(
                        Icons.drag_handle,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
              enabled: !actionsDisabled,
              onTap: actionsDisabled ? null : onTap,
            ),
          ),
        );
      },
      loading: () => ListTile(
        key: key,
        leading: const SizedBox(
          width: 48,
          height: 48,
          child: Center(child: CircularProgressIndicator()),
        ),
        title: Text(l10n.commonLoading),
      ),
      error: (error, _) => ListTile(
        key: key,
        title: Text(l10n.queueTrackLoadError),
        subtitle: Text(l10n.queueTrackLoadErrorDescription),
        trailing: IconButton(
          tooltip: l10n.commonRemove,
          onPressed: actionsDisabled ? null : onRemove,
          icon: const Icon(Icons.delete_outline),
        ),
      ),
    );
  }
}
