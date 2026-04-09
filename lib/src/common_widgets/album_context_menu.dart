import 'dart:async';

import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/desktop/desktop_context_menu.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/utils/file_utils.dart';

import 'package:navis/src/features/sharing/presentation/share_actions.dart';

/// Shows a bottom sheet context menu for an album identified by [albumId].
///
/// Actions: Open, Play, Add to Queue, Like/Unlike, Download.
Future<void> showAlbumContextMenu(
  BuildContext context,
  WidgetRef ref,
  String albumId, {
  Offset? anchor,
}) async {
  if (anchor != null && isDesktopRuntime) {
    await _showDesktopAlbumContextMenu(
      context,
      ref,
      albumId,
      anchor: anchor,
    );
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) {
      return Consumer(
        builder: (ctx, menuRef, _) {
          final l10n = AppLocalizations.of(context)!;
          final albumAsync = menuRef.watch(albumProvider(albumId));
          final album = albumAsync.asData?.value;
          final songs = album?.songs ?? const <SongsTableData>[];
          final isStarred = album?.album.starred != null;
          final isFullyDownloaded =
              songs.isNotEmpty &&
              songs.every(
                (s) =>
                    menuRef.watch(songDownloadStateProvider(s.id)).status ==
                    SongDownloadStatus.downloaded,
              );

          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.open_in_new_outlined),
                  title: Text(l10n.libraryAlbumMenuOpen),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    ref
                        .read(librarySyncControllerProvider.notifier)
                        .registerAlbumInteraction(albumId);
                    unawaited(context.push('/library/albums/$albumId'));
                  },
                ),
                ListTile(
                  enabled: songs.isNotEmpty,
                  leading: const Icon(Icons.play_arrow_outlined),
                  title: Text(l10n.libraryAlbumMenuPlay),
                  onTap: songs.isEmpty
                      ? null
                      : () {
                          Navigator.of(sheetContext).pop();
                          unawaited(
                            ref
                                .read(queueProvider.notifier)
                                .replaceWithTableData(songs),
                          );
                        },
                ),
                ListTile(
                  enabled: songs.isNotEmpty,
                  leading: const Icon(Icons.queue_music_outlined),
                  title: Text(l10n.libraryAlbumMenuAddToQueue),
                  onTap: songs.isEmpty
                      ? null
                      : () {
                          Navigator.of(sheetContext).pop();
                          unawaited(() async {
                            final localizations = AppLocalizations.of(context)!;
                            for (final song in songs) {
                              try {
                                await ref
                                    .read(queueProvider.notifier)
                                    .add(song.id);
                              } on Object {
                                if (!context.mounted) return;
                                _showQueueActionToast(
                                  context,
                                  localizations.playbackActionFailed,
                                );
                                return;
                              }
                            }
                            if (!context.mounted) return;
                            _showQueueActionToast(
                              context,
                              localizations.libraryAlbumAddedToQueue,
                            );
                          }());
                        },
                ),
                ListTile(
                  leading: Icon(
                    isStarred ? Icons.favorite : Icons.favorite_border,
                  ),
                  title: Text(
                    isStarred ? l10n.actionLiked : l10n.actionLike,
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_toggleAlbumStar(ref, albumId, isStarred));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.share_outlined),
                  title: Text(l10n.shareAction),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(shareAlbum(context, ref, albumId));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.link_outlined),
                  title: Text(l10n.copyLinkAction),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(
                      shareAlbum(context, ref, albumId, copyOnly: true),
                    );
                  },
                ),
                if (isFullyDownloaded)
                  ListTile(
                    leading: Icon(
                      Icons.delete_outlined,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    title: Text(
                      l10n.deleteDownloadAction,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_deleteAlbumDownloads(context, menuRef, songs));
                    },
                  )
                else
                  ListTile(
                    leading: const Icon(Icons.download_outlined),
                    title: Text(l10n.libraryAlbumMenuDownload),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_downloadAlbumFromMenu(context, ref, albumId));
                    },
                  ),
              ],
            ),
          );
        },
      );
    },
  );
}

enum _AlbumContextAction {
  open,
  play,
  addToQueue,
  toggleLike,
  share,
  copyLink,
  download,
  deleteDownload,
}

Future<void> _showDesktopAlbumContextMenu(
  BuildContext context,
  WidgetRef ref,
  String albumId, {
  required Offset anchor,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final albumAsync = ref.read(albumProvider(albumId));
  final album = albumAsync.asData?.value;
  final songs = album?.songs ?? const <SongsTableData>[];
  final isStarred = album?.album.starred != null;
  final isFullyDownloaded =
      songs.isNotEmpty &&
      songs.every(
        (s) =>
            ref.read(songDownloadStateProvider(s.id)).status ==
            SongDownloadStatus.downloaded,
      );

  final action = await showDesktopContextMenu<_AlbumContextAction>(
    context: context,
    anchor: anchor,
    items: <PopupMenuEntry<_AlbumContextAction>>[
      PopupMenuItem<_AlbumContextAction>(
        value: _AlbumContextAction.open,
        child: Text(l10n.libraryAlbumMenuOpen),
      ),
      PopupMenuItem<_AlbumContextAction>(
        value: _AlbumContextAction.play,
        enabled: songs.isNotEmpty,
        child: Text(l10n.libraryAlbumMenuPlay),
      ),
      PopupMenuItem<_AlbumContextAction>(
        value: _AlbumContextAction.addToQueue,
        enabled: songs.isNotEmpty,
        child: Text(l10n.libraryAlbumMenuAddToQueue),
      ),
      PopupMenuItem<_AlbumContextAction>(
        value: _AlbumContextAction.toggleLike,
        child: Text(isStarred ? l10n.actionLiked : l10n.actionLike),
      ),
      PopupMenuItem<_AlbumContextAction>(
        value: _AlbumContextAction.share,
        child: Text(l10n.shareAction),
      ),
      PopupMenuItem<_AlbumContextAction>(
        value: _AlbumContextAction.copyLink,
        child: Text(l10n.copyLinkAction),
      ),
      PopupMenuItem<_AlbumContextAction>(
        value: isFullyDownloaded
            ? _AlbumContextAction.deleteDownload
            : _AlbumContextAction.download,
        child: Text(
          isFullyDownloaded
              ? l10n.deleteDownloadAction
              : l10n.libraryAlbumMenuDownload,
        ),
      ),
    ],
  );

  if (!context.mounted || action == null) {
    return;
  }

  switch (action) {
    case _AlbumContextAction.open:
      ref
          .read(librarySyncControllerProvider.notifier)
          .registerAlbumInteraction(albumId);
      unawaited(context.push('/library/albums/$albumId'));
      return;
    case _AlbumContextAction.play:
      if (songs.isEmpty) {
        return;
      }
      await ref.read(queueProvider.notifier).replaceWithTableData(songs);
      return;
    case _AlbumContextAction.addToQueue:
      final localizations = AppLocalizations.of(context)!;
      for (final song in songs) {
        await ref.read(queueProvider.notifier).add(song.id);
      }
      if (context.mounted) {
        _showQueueActionToast(
          context,
          localizations.libraryAlbumAddedToQueue,
        );
      }
      return;
    case _AlbumContextAction.toggleLike:
      await _toggleAlbumStar(ref, albumId, isStarred);
      return;
    case _AlbumContextAction.share:
      await shareAlbum(context, ref, albumId);
      return;
    case _AlbumContextAction.copyLink:
      await shareAlbum(context, ref, albumId, copyOnly: true);
      return;
    case _AlbumContextAction.download:
      await _downloadAlbumFromMenu(context, ref, albumId);
      return;
    case _AlbumContextAction.deleteDownload:
      await _deleteAlbumDownloads(context, ref, songs);
      return;
  }
}

void _showQueueActionToast(BuildContext context, String message) {
  final messenger = AppNoticeMessenger.of(context);
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(message)));
}

Future<void> _downloadAlbumFromMenu(
  BuildContext context,
  WidgetRef ref,
  String albumId,
) async {
  if (!context.mounted) return;
  final choice = await showDownloadQualitySheet(context);
  if (choice == null || !context.mounted) return;
  final service = ref.read(downloadServiceProvider);
  final count = await service.enqueueAlbum(
    albumId,
    quality: choice.quality,
    format: choice.format,
  );
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  AppNoticeMessenger.of(context).showSnackBar(
    SnackBar(content: Text(l10n.downloadAlbumQueued(count))),
  );
}

/// Deletes all permanently-downloaded songs in [songs] one by one,
/// delegating each to [confirmAndDeleteDownload] — which shows a confirmation
/// dialog before the first song, then proceeds.
///
/// To avoid multiple dialogs the function confirms once and then removes all
/// songs directly.
Future<void> _deleteAlbumDownloads(
  BuildContext context,
  WidgetRef ref,
  List<SongsTableData> songs,
) async {
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.downloadsRemoveConfirmTitle),
      content: Text(l10n.downloadsRemoveConfirmContent),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(l10n.cancelAction),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(l10n.downloadsRemoveAction),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final cacheDao = ref.read(navisDatabaseProvider).cacheDao;
  for (final song in songs) {
    final track = await cacheDao.getCachedTrack(song.id);
    if (track != null) {
      await deleteFileWithSuffixes(track.filePath);
    }
    await cacheDao.removeCachedTrack(song.id);
  }
}

Future<void> _toggleAlbumStar(
  WidgetRef ref,
  String albumId,
  bool isStarred,
) async {
  final dao = ref.read(navisDatabaseProvider).libraryDao;

  // Optimistic DB update FIRST — Drift fires stream notification immediately
  // so any screen watching albumProvider(albumId) or the liked albums
  // providers (library, home) updates right away, without waiting ~300 ms for
  // the server round-trip.
  await dao.updateAlbumStarred(albumId, isStarred ? null : DateTime.now());

  final api = ref.read(subsonicApiProvider);
  if (api == null) return;
  try {
    if (isStarred) {
      await api.unstar(albumId);
    } else {
      await api.star(albumId);
    }
  } on SubsonicConnectionException {
    // Offline — the optimistic DB state is kept; just queue for server sync.
    await ref
        .read(navisDatabaseProvider)
        .starSyncDao
        .queueStarAction(
          itemId: albumId,
          itemType: 'album',
          action: isStarred ? 'unstar' : 'star',
        );
  } catch (_) {
    // API error — rollback the optimistic DB update.
    await dao.updateAlbumStarred(albumId, isStarred ? DateTime.now() : null);
  }
}
