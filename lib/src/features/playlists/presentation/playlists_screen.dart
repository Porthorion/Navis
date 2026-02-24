import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';

class PlaylistsScreen extends ConsumerStatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  ConsumerState<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends ConsumerState<PlaylistsScreen> {
  @override
  void initState() {
    super.initState();
    // Trigger initial sync from server
    Future.microtask(() => ref.invalidate(playlistSyncProvider));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final playlistsAsync = ref.watch(playlistListProvider);
    // Keep the sync provider alive so it runs eagerly
    ref.watch(playlistSyncProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.playlistsTitle)),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreatePlaylistDialog(context),
        tooltip: l10n.playlistsCreateAction,
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(playlistSyncProvider);
          await ref.read(playlistSyncProvider.future);
        },
        child: playlistsAsync.when(
          data: (playlists) {
            if (playlists.isEmpty) {
              return ListView(
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: EmptyState(
                      title: l10n.playlistsEmpty,
                      subtitle: l10n.playlistsEmptySubtitle,
                      icon: Icons.queue_music_outlined,
                    ),
                  ),
                ],
              );
            }

            return ListView.builder(
              padding: const EdgeInsets.only(bottom: 80),
              itemCount: playlists.length,
              itemBuilder: (context, index) {
                final playlist = playlists[index];
                return _PlaylistTile(
                  playlist: playlist,
                  onTap: () => context.push('/playlists/${playlist.id}'),
                  onLongPress: () => _showPlaylistActions(context, playlist),
                );
              },
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => ErrorState(
            title: l10n.playlistsLoadError,
            message: error.toString(),
            onRetry: () => ref.invalidate(playlistSyncProvider),
          ),
        ),
      ),
    );
  }

  void _showCreatePlaylistDialog(BuildContext context) {
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
          onSubmitted: (_) =>
              _createPlaylist(dialogContext, controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            onPressed: () =>
                _createPlaylist(dialogContext, controller.text.trim()),
            child: Text(l10n.playlistsCreateAction),
          ),
        ],
      ),
    );
  }

  void _createPlaylist(BuildContext dialogContext, String name) {
    if (name.isEmpty) return;
    Navigator.of(dialogContext).pop();

    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;

    unawaited(
      api
          .createPlaylist(name)
          .then((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.playlistsCreateSuccess)),
            );
            ref.invalidate(playlistSyncProvider);
          })
          .catchError((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.playlistsCreateFailed)),
            );
          }),
    );
  }

  void _showPlaylistActions(
    BuildContext context,
    PlaylistsTableData playlist,
  ) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(l10n.playlistsRenameTitle),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _showRenameDialog(context, playlist);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                l10n.playlistsDeleteConfirmTitle,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _confirmDelete(context, playlist);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showRenameDialog(
    BuildContext context,
    PlaylistsTableData playlist,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: playlist.name);

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.playlistsRenameTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: l10n.playlistsRenameLabel),
          onSubmitted: (_) => _renamePlaylist(
            dialogContext,
            playlist.id,
            controller.text.trim(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            onPressed: () => _renamePlaylist(
              dialogContext,
              playlist.id,
              controller.text.trim(),
            ),
            child: Text(l10n.playlistsRenameTitle),
          ),
        ],
      ),
    );
  }

  void _renamePlaylist(
    BuildContext dialogContext,
    String playlistId,
    String newName,
  ) {
    if (newName.isEmpty) return;
    Navigator.of(dialogContext).pop();

    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;

    unawaited(
      api
          .updatePlaylist(id: playlistId, name: newName)
          .then((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.playlistsRenameSuccess)),
            );
            ref.invalidate(playlistSyncProvider);
          })
          .catchError((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.playlistsRenameFailed)),
            );
          }),
    );
  }

  void _confirmDelete(
    BuildContext context,
    PlaylistsTableData playlist,
  ) {
    final l10n = AppLocalizations.of(context)!;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.playlistsDeleteConfirmTitle),
        content: Text(l10n.playlistsDeleteConfirmMessage(playlist.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _deletePlaylist(playlist.id);
            },
            child: Text(l10n.playlistsDeleteConfirmTitle),
          ),
        ],
      ),
    );
  }

  void _deletePlaylist(String playlistId) {
    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;

    unawaited(
      api
          .deletePlaylist(playlistId)
          .then((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.playlistsDeleteSuccess)),
            );
            ref.invalidate(playlistSyncProvider);
          })
          .catchError((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.playlistsDeleteFailed)),
            );
          }),
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({
    required this.playlist,
    this.onTap,
    this.onLongPress,
  });

  final PlaylistsTableData playlist;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListTile(
      leading: CoverArtImage(
        coverArtId: playlist.coverArt,
        size: 200,
        width: 48,
        height: 48,
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
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
