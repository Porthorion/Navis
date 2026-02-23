import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Shows a bottom sheet that lets the user pick a playlist to add
/// the given [songIds] to. Also offers a "New playlist" option at the top.
Future<void> showAddToPlaylistSheet(
  BuildContext context,
  WidgetRef ref,
  List<String> songIds,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.8,
      expand: false,
      builder: (context, scrollController) => _AddToPlaylistSheet(
        songIds: songIds,
        scrollController: scrollController,
      ),
    ),
  );
}

class _AddToPlaylistSheet extends ConsumerWidget {
  const _AddToPlaylistSheet({
    required this.songIds,
    required this.scrollController,
  });

  final List<String> songIds;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final playlistsAsync = ref.watch(playlistListProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Text(
                l10n.addToPlaylistTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.add),
          title: Text(l10n.addToPlaylistNewPlaylist),
          onTap: () {
            Navigator.of(context).pop();
            _showCreateAndAddDialog(context, ref);
          },
        ),
        Expanded(
          child: playlistsAsync.when(
            data: (playlists) {
              if (playlists.isEmpty) {
                return Center(
                  child: Text(
                    l10n.playlistsEmpty,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.6),
                    ),
                  ),
                );
              }

              return ListView.builder(
                controller: scrollController,
                itemCount: playlists.length,
                itemBuilder: (context, index) {
                  final playlist = playlists[index];
                  return ListTile(
                    leading: CoverArtImage(
                      coverArtId: playlist.coverArt,
                      size: 200,
                      width: 40,
                      height: 40,
                      borderRadius: BorderRadius.circular(4),
                      placeholderIcon: Icons.queue_music,
                    ),
                    title: Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      l10n.playlistsSongCount(playlist.songCount ?? 0),
                    ),
                    onTap: () => _addToPlaylist(
                      context,
                      ref,
                      playlist.id,
                      playlist.name,
                    ),
                  );
                },
              );
            },
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (_, _) => Center(child: Text(l10n.playlistsLoadError)),
          ),
        ),
      ],
    );
  }

  void _addToPlaylist(
    BuildContext context,
    WidgetRef ref,
    String playlistId,
    String playlistName,
  ) {
    Navigator.of(context).pop();
    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;

    unawaited(
      api
          .updatePlaylist(id: playlistId, songIdsToAdd: songIds)
          .then((_) {
        ref.invalidate(playlistDetailSyncProvider(playlistId));
        ref.invalidate(playlistSyncProvider);
      }),
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.addToPlaylistSuccess(playlistName))),
    );
  }

  void _showCreateAndAddDialog(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.playlistsCreateTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: l10n.playlistsCreateNameLabel),
          onSubmitted: (_) => _createAndAdd(
            dialogContext,
            context,
            ref,
            controller.text.trim(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            onPressed: () => _createAndAdd(
              dialogContext,
              context,
              ref,
              controller.text.trim(),
            ),
            child: Text(l10n.playlistsCreateAction),
          ),
        ],
      ),
    );
  }

  void _createAndAdd(
    BuildContext dialogContext,
    BuildContext parentContext,
    WidgetRef ref,
    String name,
  ) {
    if (name.isEmpty) return;
    Navigator.of(dialogContext).pop();

    final l10n = AppLocalizations.of(parentContext)!;
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;

    unawaited(
      api.createPlaylist(name, songIds: songIds).then((_) {
        ref.invalidate(playlistSyncProvider);
        if (parentContext.mounted) {
          ScaffoldMessenger.of(parentContext).showSnackBar(
            SnackBar(content: Text(l10n.playlistsCreateSuccess)),
          );
        }
      }).catchError((_) {
        if (parentContext.mounted) {
          ScaffoldMessenger.of(parentContext).showSnackBar(
            SnackBar(content: Text(l10n.playlistsCreateFailed)),
          );
        }
      }),
    );
  }
}
