import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart'
    show songByIdProvider, subsonicApiProvider;

class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final queueIds = ref.watch(queueProvider);
    final currentSongId = ref.watch(currentQueueSongIdProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.queueTitle),
        actions: [
          if (queueIds.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.playlist_add),
              tooltip: l10n.queueSaveAsPlaylist,
              onPressed: () => _showSaveAsPlaylistDialog(
                context,
                ref,
                queueIds,
              ),
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
      body: queueIds.isEmpty
          ? EmptyState(
              title: l10n.queueEmptyTitle,
              subtitle: l10n.queueEmptySubtitle,
              icon: Icons.queue_music_outlined,
            )
          : ReorderableListView.builder(
              padding: const EdgeInsets.only(bottom: 80),
              itemCount: queueIds.length,
              onReorder: (oldIndex, newIndex) async {
                await ref.read(reorderQueueProvider)(oldIndex, newIndex);
              },
              itemBuilder: (context, index) {
                final songId = queueIds[index];
                final isCurrentSong = songId == currentSongId;

                return _QueueItem(
                  key: ValueKey('$index-$songId'),
                  songId: songId,
                  index: index,
                  isCurrentSong: isCurrentSong,
                  onRemove: () async {
                    await ref.read(queueProvider.notifier).removeAt(index);
                  },
                  onTap: () async {
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
          decoration: InputDecoration(
            labelText: l10n.queueSaveAsPlaylistName,
          ),
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
    api.createPlaylist(name, songIds: queueIds).then((_) {
      if (parentContext.mounted) {
        showAppNotice(parentContext, message: l10n.queueSaveAsPlaylistSaved, level: AppNoticeLevel.success);
      }
    });
  }
}

class _QueueItem extends ConsumerWidget {
  const _QueueItem({
    required super.key,
    required this.songId,
    required this.index,
    required this.isCurrentSong,
    required this.onRemove,
    required this.onTap,
  });

  final String songId;
  final int index;
  final bool isCurrentSong;
  final VoidCallback onRemove;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final songAsync = ref.watch(songByIdProvider(songId));

    return songAsync.when(
      data: (song) {
        if (song == null) {
          return ListTile(
            key: key,
            title: Text(l10n.queueUnknownTrack),
            subtitle: Text('ID: $songId'),
          );
        }

        return Dismissible(
          key: key!,
          direction: DismissDirection.endToStart,
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
          child: ListTile(
            leading: CoverArtImage(
              coverArtId: song.coverArt,
              size: kCoverArtStandardSize,
              width: 48,
              height: 48,
              borderRadius: BorderRadius.circular(4),
            ),
            title: Text(
              song.title,
              style: isCurrentSong
                  ? TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    )
                  : null,
            ),
            subtitle: Text(song.artistName ?? l10n.queueUnknownArtist),
            trailing: ReorderableDragStartListener(
              index: index,
              child: Icon(
                Icons.drag_handle,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            onTap: onTap,
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
        subtitle: Text(error.toString()),
      ),
    );
  }
}
