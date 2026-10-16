import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/features/player/presentation/queue_current_row_centering.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/queue_track_row.dart';
import 'package:navis/src/features/player/presentation/queue_unavailable_tracks.dart';
import 'package:navis/src/features/playlists/presentation/create_playlist_dialog.dart';
import 'package:navis/src/providers/app_providers.dart'
    show playerStateProvider;

class QueueScreen extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final queueIds = ref.watch(queueProvider);
    final retained = ref.watch(retainedArtistQueueProvider);
    final playback = ref.watch(playerStateProvider);
    // Same guard as QueueSheet: the logical queue is still being replaced.
    final actionsDisabled = queueActionsDisabled(playback);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.queueTitle),
        actions: [
          if (queueIds.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.playlist_add),
              tooltip: l10n.queueSaveAsPlaylist,
              onPressed: () =>
                  showCreatePlaylistDialog(context, ref, songIds: queueIds),
            ),
          if (queueIds.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear_all),
              tooltip: l10n.queueClearAction,
              onPressed: () => confirmAndClearQueue(context, ref),
            ),
        ],
      ),
      body: queueIds.isEmpty && retained.isEmpty
          ? EmptyState(
              title: l10n.queueEmptyTitle,
              subtitle: l10n.queueEmptySubtitle,
              icon: Icons.queue_music_outlined,
            )
          : QueueCurrentRowCentering(
              currentIndex: queueCurrentIndex(playback, queueIds),
              child: ReorderableListView.builder(
                footer: const QueueUnavailableTracks(),
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: queueIds.length,
                onReorderItem: (oldIndex, newIndex) async {
                  if (actionsDisabled) return;
                  await reorderQueueItem(ref, oldIndex, newIndex);
                },
                itemBuilder: (context, index) {
                  return QueueTrackRow(
                    key: queueRowKey(queueIds, index),
                    songId: queueIds[index],
                    index: index,
                    indicatorState: queueRowIndicatorState(
                      playback,
                      queueIds,
                      index,
                    ),
                    actionsDisabled: actionsDisabled,
                    onRemove: () async {
                      if (actionsDisabled) return;
                      await ref.read(queueProvider.notifier).removeAt(index);
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
    );
  }
}
