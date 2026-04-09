import 'dart:async';

import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/desktop/desktop_context_menu.dart';
import 'package:navis/src/common_widgets/rating_widget.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/set_rating.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/library/domain/toggle_song_star.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/playlists/presentation/add_to_playlist_sheet.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/utils/song_id_utils.dart';

import 'package:navis/src/features/sharing/presentation/share_actions.dart';

/// Shows a generic bottom sheet context menu for a [SongsTableData] song.
///
/// Includes: Play Now, Add to Queue, Play Next, Open Artist, Open Album,
/// Add to Playlist, and a toggled Download / Delete Download action.
Future<void> showSongContextMenu(
  BuildContext context,
  WidgetRef ref,
  SongsTableData song, {
  Offset? anchor,
}) async {
  if (anchor != null && isDesktopRuntime) {
    await _showDesktopSongContextMenu(
      context,
      ref,
      song,
      anchor: anchor,
    );
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      return Consumer(
        builder: (ctx, menuRef, _) {
          final l10n = AppLocalizations.of(context)!;
          final downloadState = menuRef.watch(
            songDownloadStateProvider(song.id),
          );
          final isDownloaded =
              downloadState.status == SongDownloadStatus.downloaded;
          final canDownload =
              downloadState.status == SongDownloadStatus.none ||
              downloadState.status == SongDownloadStatus.cached;
          final isLiked =
              menuRef.watch(songStarredProvider(song.id)).asData?.value ??
              song.starred != null;
          final rating = menuRef
              .watch(songRatingProvider(song.id))
              .asData
              ?.value;
          final isRemote = !isServerAddressableSongId(song.id);
          final disabledColor = Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.38);

          final maxHeight = MediaQuery.of(sheetContext).size.height * 0.85;
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    ListTile(
                      leading: const Icon(Icons.play_arrow_outlined),
                      title: Text(l10n.librarySongMenuPlayNow),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(
                          ref.read(queueProvider.notifier).replaceWithTableData(
                            <SongsTableData>[song],
                          ),
                        );
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.queue_music_outlined),
                      title: Text(l10n.librarySongMenuAddToQueue),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(() async {
                          try {
                            await ref.read(queueProvider.notifier).add(song.id);
                          } on Object {
                            if (!context.mounted) return;
                            _showQueueActionToast(
                              context,
                              l10n.playbackActionFailed,
                            );
                            return;
                          }
                          if (!context.mounted) return;
                          _showQueueActionToast(
                            context,
                            l10n.librarySongAddedToQueue(song.title),
                          );
                        }());
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.playlist_add_outlined),
                      title: Text(l10n.librarySongMenuPlayNext),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(() async {
                          try {
                            await ref
                                .read(queueProvider.notifier)
                                .playNext(song.id);
                          } on Object {
                            if (!context.mounted) return;
                            _showQueueActionToast(
                              context,
                              l10n.playbackActionFailed,
                            );
                            return;
                          }
                          if (!context.mounted) return;
                          _showQueueActionToast(
                            context,
                            l10n.librarySongPlayNextQueued(song.title),
                          );
                        }());
                      },
                    ),
                    ListTile(
                      iconColor: isRemote ? disabledColor : null,
                      textColor: isRemote ? disabledColor : null,
                      leading: Icon(
                        isLiked ? Icons.favorite : Icons.favorite_border,
                      ),
                      title: Text(
                        isLiked ? l10n.actionLiked : l10n.actionLike,
                      ),
                      onTap: () {
                        if (isRemote) {
                          AppNoticeMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(l10n.remoteSourceActionUnavailable),
                            ),
                          );
                          return;
                        }
                        unawaited(
                          toggleSongStar(song.id, ref).catchError((_) {
                            if (context.mounted) {
                              AppNoticeMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(l10n.albumDetailStarFailure),
                                ),
                              );
                            }
                          }),
                        );
                      },
                    ),
                    ListTile(
                      iconColor: isRemote ? disabledColor : null,
                      textColor: isRemote ? disabledColor : null,
                      leading: const Icon(Icons.star_outline),
                      title: Text(l10n.ratingTitle),
                      subtitle: Text(l10n.ratingHint),
                      trailing: isRemote
                          ? IgnorePointer(
                              child: Opacity(
                                opacity: 0.38,
                                child: RatingWidget(
                                  rating: rating,
                                  compact: true,
                                  onChanged: (_) {},
                                ),
                              ),
                            )
                          : RatingWidget(
                              rating: rating,
                              compact: true,
                              onChanged: (next) {
                                unawaited(
                                  setSongRating(
                                    song.id,
                                    next,
                                    ref,
                                  ).catchError((_) {
                                    if (context.mounted) {
                                      AppNoticeMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            l10n.ratingUpdateFailed,
                                          ),
                                        ),
                                      );
                                    }
                                  }),
                                );
                              },
                            ),
                      onTap: isRemote
                          ? () => AppNoticeMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  l10n.remoteSourceActionUnavailable,
                                ),
                              ),
                            )
                          : null,
                    ),
                    if (song.artistId != null && song.artistId!.isNotEmpty)
                      ListTile(
                        leading: const Icon(Icons.person_outline),
                        title: Text(l10n.librarySongMenuOpenArtist),
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          context.push('/library/artists/${song.artistId}');
                        },
                      ),
                    if (song.albumId != null && song.albumId!.isNotEmpty)
                      ListTile(
                        leading: const Icon(Icons.album_outlined),
                        title: Text(l10n.librarySongMenuOpenAlbum),
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          context.push('/library/albums/${song.albumId}');
                        },
                      ),
                    ListTile(
                      leading: const Icon(Icons.playlist_add),
                      title: Text(l10n.librarySongMenuAddToPlaylist),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        showAddToPlaylistSheet(context, ref, <String>[song.id]);
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.share_outlined),
                      title: Text(l10n.shareAction),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(shareSong(context, ref, song));
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.link_outlined),
                      title: Text(l10n.copyLinkAction),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(
                          shareSong(context, ref, song, copyOnly: true),
                        );
                      },
                    ),
                    if (isDownloaded)
                      ListTile(
                        leading: Icon(
                          Icons.delete_outline,
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
                          unawaited(
                            confirmAndDeleteDownload(context, ref, song.id),
                          );
                        },
                      )
                    else if (canDownload)
                      ListTile(
                        iconColor: isRemote ? disabledColor : null,
                        textColor: isRemote ? disabledColor : null,
                        leading: const Icon(Icons.download_outlined),
                        title: Text(l10n.downloadAction),
                        onTap: () {
                          if (isRemote) {
                            AppNoticeMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  l10n.remoteSourceActionUnavailable,
                                ),
                              ),
                            );
                            return;
                          }
                          Navigator.of(sheetContext).pop();
                          unawaited(
                            _downloadSongFromMenu(context, ref, song.id),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

enum _SongContextAction {
  playNow,
  addQueue,
  playNext,
  toggleLike,
  openArtist,
  openAlbum,
  addPlaylist,
  share,
  copyLink,
  download,
  deleteDownload,
}

Future<void> _showDesktopSongContextMenu(
  BuildContext context,
  WidgetRef ref,
  SongsTableData song, {
  required Offset anchor,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final downloadState = ref.read(songDownloadStateProvider(song.id));
  final isDownloaded = downloadState.status == SongDownloadStatus.downloaded;
  final canDownload =
      downloadState.status == SongDownloadStatus.none ||
      downloadState.status == SongDownloadStatus.cached;
  final isLiked =
      ref.read(songStarredProvider(song.id)).asData?.value ??
      song.starred != null;
  final isRemote = !isServerAddressableSongId(song.id);

  final action = await showDesktopContextMenu<_SongContextAction>(
    context: context,
    anchor: anchor,
    items: <PopupMenuEntry<_SongContextAction>>[
      PopupMenuItem<_SongContextAction>(
        value: _SongContextAction.playNow,
        child: Text(l10n.librarySongMenuPlayNow),
      ),
      PopupMenuItem<_SongContextAction>(
        value: _SongContextAction.addQueue,
        child: Text(l10n.librarySongMenuAddToQueue),
      ),
      PopupMenuItem<_SongContextAction>(
        value: _SongContextAction.playNext,
        child: Text(l10n.librarySongMenuPlayNext),
      ),
      PopupMenuItem<_SongContextAction>(
        value: _SongContextAction.toggleLike,
        enabled: !isRemote,
        child: Text(isLiked ? l10n.actionLiked : l10n.actionLike),
      ),
      if (song.artistId != null && song.artistId!.isNotEmpty)
        PopupMenuItem<_SongContextAction>(
          value: _SongContextAction.openArtist,
          child: Text(l10n.librarySongMenuOpenArtist),
        ),
      if (song.albumId != null && song.albumId!.isNotEmpty)
        PopupMenuItem<_SongContextAction>(
          value: _SongContextAction.openAlbum,
          child: Text(l10n.librarySongMenuOpenAlbum),
        ),
      PopupMenuItem<_SongContextAction>(
        value: _SongContextAction.addPlaylist,
        child: Text(l10n.librarySongMenuAddToPlaylist),
      ),
      PopupMenuItem<_SongContextAction>(
        value: _SongContextAction.share,
        child: Text(l10n.shareAction),
      ),
      PopupMenuItem<_SongContextAction>(
        value: _SongContextAction.copyLink,
        child: Text(l10n.copyLinkAction),
      ),
      PopupMenuItem<_SongContextAction>(
        value: isDownloaded
            ? _SongContextAction.deleteDownload
            : _SongContextAction.download,
        enabled: isDownloaded || (canDownload && !isRemote),
        child: Text(
          isDownloaded ? l10n.deleteDownloadAction : l10n.downloadAction,
        ),
      ),
    ],
  );

  if (!context.mounted || action == null) {
    return;
  }

  switch (action) {
    case _SongContextAction.playNow:
      await ref.read(queueProvider.notifier).replaceWithTableData(
        <SongsTableData>[song],
      );
      return;
    case _SongContextAction.addQueue:
      await ref.read(queueProvider.notifier).add(song.id);
      if (context.mounted) {
        _showQueueActionToast(
          context,
          l10n.librarySongAddedToQueue(song.title),
        );
      }
      return;
    case _SongContextAction.playNext:
      await ref.read(queueProvider.notifier).playNext(song.id);
      if (context.mounted) {
        _showQueueActionToast(
          context,
          l10n.librarySongPlayNextQueued(song.title),
        );
      }
      return;
    case _SongContextAction.toggleLike:
      try {
        await toggleSongStar(song.id, ref);
      } on Object {
        if (context.mounted) {
          AppNoticeMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.albumDetailStarFailure)),
          );
        }
      }
      return;
    case _SongContextAction.openArtist:
      unawaited(context.push('/library/artists/${song.artistId}'));
      return;
    case _SongContextAction.openAlbum:
      unawaited(context.push('/library/albums/${song.albumId}'));
      return;
    case _SongContextAction.addPlaylist:
      await showAddToPlaylistSheet(context, ref, <String>[song.id]);
      return;
    case _SongContextAction.share:
      await shareSong(context, ref, song);
      return;
    case _SongContextAction.copyLink:
      await shareSong(context, ref, song, copyOnly: true);
      return;
    case _SongContextAction.download:
      await _downloadSongFromMenu(context, ref, song.id);
      return;
    case _SongContextAction.deleteDownload:
      await confirmAndDeleteDownload(context, ref, song.id);
      return;
  }
}

void _showQueueActionToast(BuildContext context, String message) {
  final messenger = AppNoticeMessenger.of(context);
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Downloads [songId] after showing the quality picker.
Future<void> _downloadSongFromMenu(
  BuildContext context,
  WidgetRef ref,
  String songId,
) async {
  if (!context.mounted) return;
  final choice = await showDownloadQualitySheet(context);
  if (choice == null || !context.mounted) return;
  final service = ref.read(downloadServiceProvider);
  unawaited(
    service.enqueueSong(
      songId,
      quality: choice.quality,
      format: choice.format,
    ),
  );
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  AppNoticeMessenger.of(context).showSnackBar(
    SnackBar(content: Text(l10n.downloadSongQueued)),
  );
}
