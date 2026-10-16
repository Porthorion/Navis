import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/playlists/data/playlist_actions.dart';
import 'package:navis/src/features/playlists/domain/playlist_ownership.dart';
import 'package:navis/src/features/playlists/presentation/create_playlist_dialog.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/theme/artwork_shape.dart';

/// Shows a bottom sheet that lets the user pick a playlist to add
/// the given [songIds] to. Also offers a "New playlist" option at the top.
Future<void> showAddToPlaylistSheet(
  BuildContext context,
  WidgetRef ref,
  List<String> songIds,
) async {
  if (isDesktopRuntime) {
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) {
        final availableHeight = MediaQuery.sizeOf(dialogContext).height - 96;
        return Dialog(
          child: SizedBox(
            width: 460,
            height: availableHeight.clamp(320.0, 560.0),
            child: _AddToPlaylistSheet(songIds: songIds, launcher: context),
          ),
        );
      },
    );
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (sheetContext) => DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.8,
      expand: false,
      builder: (_, scrollController) => _AddToPlaylistSheet(
        songIds: songIds,
        launcher: context,
        scrollController: scrollController,
      ),
    ),
  );
}

class _AddToPlaylistSheet extends ConsumerWidget {
  const new({
    required this.songIds,
    required this.launcher,
    this.scrollController,
  });

  final List<String> songIds;

  /// The context that opened the sheet; it outlives the sheet, so notices
  /// shown after the sheet closes still find their host.
  final BuildContext launcher;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final me = ref.watch(playlistViewerProvider);
    final playlistsAsync = ref
        .watch(playlistListProvider)
        .whenData(
          (all) => all
              .where((playlist) => canEditPlaylist(playlist, me))
              .toList(growable: false),
        );

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
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
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
            unawaited(
              showCreatePlaylistDialog(launcher, ref, songIds: songIds),
            );
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
                      color: Theme.of(context).colorScheme.onSurface
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
                      size: kCoverArtStandardSize,
                      width: 40,
                      height: 40,
                      shape: ArtworkShapeRole.cover,
                      placeholderIcon: Icons.queue_music,
                    ),
                    title: Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      playlist.isLocal
                          ? l10n.playlistDetailMeta(
                              l10n.playlistsOnDevice,
                              playlist.songCount ?? 0,
                            )
                          : l10n.playlistsSongCount(playlist.songCount ?? 0),
                    ),
                    onTap: () => _addToPlaylist(context, ref, playlist),
                  );
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => Center(child: Text(l10n.playlistsLoadError)),
          ),
        ),
      ],
    );
  }

  void _addToPlaylist(
    BuildContext context,
    WidgetRef ref,
    PlaylistsTableData playlist,
  ) {
    final actions = ref.read(playlistActionsProvider);
    Navigator.of(context).pop();
    unawaited(_add(actions, playlist));
  }

  Future<void> _add(
    PlaylistActions actions,
    PlaylistsTableData playlist,
  ) async {
    final l10n = AppLocalizations.of(launcher)!;
    var skipped = 0;
    var failed = false;
    try {
      skipped = await actions.addSongs(playlist, songIds);
      failed = skipped >= songIds.length;
    } on Object {
      failed = true;
    }
    if (!launcher.mounted) return;
    final partial = !failed && skipped > 0;
    showAppNotice(
      launcher,
      message: failed
          ? l10n.addToPlaylistFailed
          : partial
          ? l10n.addToPlaylistPartial(playlist.name, skipped)
          : l10n.addToPlaylistSuccess(playlist.name),
      level: failed
          ? AppNoticeLevel.error
          : partial
          ? AppNoticeLevel.info
          : AppNoticeLevel.success,
    );
  }
}
