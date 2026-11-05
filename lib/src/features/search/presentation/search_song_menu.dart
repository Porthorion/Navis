import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/desktop/desktop_context_menu.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/smart_queue_sheet.dart';
import 'package:navis/src/features/playlists/presentation/add_to_playlist_sheet.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';

/// The menu of a song in Search: a popup at [anchor] (desktop), else a bottom
/// sheet. Used by the song rows and by the Top Results card.
void showSearchSongMenu(
  BuildContext context,
  WidgetRef ref,
  Song song, {
  Offset? anchor,
}) {
  final l10n = AppLocalizations.of(context)!;
  if (anchor != null && isDesktopRuntime) {
    final result = showDesktopContextMenu<String>(
      context: context,
      anchor: anchor,
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'play-next',
          child: Text(l10n.searchPlayNext),
        ),
        PopupMenuItem<String>(
          value: 'add-queue',
          child: Text(l10n.searchAddToQueue),
        ),
        PopupMenuItem<String>(
          value: 'add-playlist',
          child: Text(l10n.librarySongMenuAddToPlaylist),
        ),
        PopupMenuItem<String>(
          value: 'instant-mix',
          child: Text(l10n.nowPlayingInstantMix),
        ),
      ],
    );
    unawaited(
      result.then((value) {
        if (!context.mounted) return;
        switch (value) {
          case 'play-next':
            ref
                .read(queueProvider.notifier)
                .fireAndForget(
                  () => ref.read(queueProvider.notifier).playNextWithSong(song),
                  label: 'playNext',
                );
            if (context.mounted) {
              showAppNotice(
                context,
                message: l10n.librarySongPlayNextQueued(song.title),
                level: AppNoticeLevel.success,
              );
            }
            return;
          case 'add-queue':
            ref
                .read(queueProvider.notifier)
                .fireAndForget(
                  () => ref.read(queueProvider.notifier).addWithSong(song),
                  label: 'addToQueue',
                );
            if (context.mounted) {
              showAppNotice(
                context,
                message: l10n.librarySongAddedToQueue(song.title),
                level: AppNoticeLevel.success,
              );
            }
            return;
          case 'add-playlist':
            unawaited(showAddToPlaylistSheet(context, ref, [song.id]));
            return;
          case 'instant-mix':
            unawaited(activatePreferredMixMode(ref, seedSongId: song.id));
            return;
          default:
            return;
        }
      }),
    );
    return;
  }
  showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.play_arrow),
            title: Text(l10n.searchPlayNext),
            onTap: () {
              Navigator.of(sheetContext).pop();
              ref
                  .read(queueProvider.notifier)
                  .fireAndForget(
                    () =>
                        ref.read(queueProvider.notifier).playNextWithSong(song),
                    label: 'playNext',
                  );
              if (context.mounted) {
                showAppNotice(
                  context,
                  message: l10n.librarySongPlayNextQueued(song.title),
                  level: AppNoticeLevel.success,
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.queue_music),
            title: Text(l10n.searchAddToQueue),
            onTap: () {
              Navigator.of(sheetContext).pop();
              ref
                  .read(queueProvider.notifier)
                  .fireAndForget(
                    () => ref.read(queueProvider.notifier).addWithSong(song),
                    label: 'addToQueue',
                  );
              if (context.mounted) {
                showAppNotice(
                  context,
                  message: l10n.librarySongAddedToQueue(song.title),
                  level: AppNoticeLevel.success,
                );
              }
            },
          ),
          if (song.albumId != null)
            ListTile(
              leading: const Icon(Icons.album),
              title: Text(l10n.nowPlayingGoToAlbum),
              onTap: () {
                Navigator.of(sheetContext).pop();
                NavService.openAlbumDetail(
                  context,
                  ref,
                  song.albumId!,
                  name: song.album,
                  artistName: song.artist,
                );
              },
            ),
          if (song.artistId != null)
            ListTile(
              leading: const Icon(Icons.person),
              title: Text(l10n.nowPlayingGoToArtist),
              onTap: () {
                Navigator.of(sheetContext).pop();
                NavService.openArtistDetail(
                  context,
                  ref,
                  song.artistId!,
                  name: song.artist,
                );
              },
            ),
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: Text(l10n.librarySongMenuAddToPlaylist),
            onTap: () {
              Navigator.of(sheetContext).pop();
              unawaited(showAddToPlaylistSheet(context, ref, [song.id]));
            },
          ),
          ListTile(
            leading: const Icon(Icons.explore),
            title: Text(l10n.nowPlayingInstantMix),
            onTap: () {
              Navigator.of(sheetContext).pop();
              unawaited(activatePreferredMixMode(ref, seedSongId: song.id));
            },
          ),
        ],
      ),
    ),
  );
}
