import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/rating_widget.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/set_rating.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/library/domain/toggle_song_star.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/playlists/presentation/add_to_playlist_sheet.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/file_utils.dart';

/// Shows a generic bottom sheet context menu for a [SongsTableData] song.
///
/// Includes: Play Now, Add to Queue, Play Next, Open Artist, Open Album,
/// Add to Playlist, and a toggled Download / Delete Download action.
Future<void> showSongContextMenu(
  BuildContext context,
  WidgetRef ref,
  SongsTableData song,
) async {
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
          final isLiked =
              menuRef.watch(songStarredProvider(song.id)).asData?.value ??
              song.starred != null;
            final rating =
              menuRef.watch(songRatingProvider(song.id)).asData?.value;

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
                      ref.read(queueProvider.notifier).replace(<String>[
                        song.id,
                      ]),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.queue_music_outlined),
                  title: Text(l10n.librarySongMenuAddToQueue),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(ref.read(queueProvider.notifier).add(song.id));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_add_outlined),
                  title: Text(l10n.librarySongMenuPlayNext),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(
                      ref.read(queueProvider.notifier).playNext(song.id),
                    );
                  },
                ),
                ListTile(
                  leading: Icon(
                    isLiked ? Icons.favorite : Icons.favorite_border,
                  ),
                  title: Text(
                    isLiked ? l10n.actionLiked : l10n.actionLike,
                  ),
                  onTap: () {
                    unawaited(
                      toggleSongStar(song.id, ref).catchError((_) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
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
                  leading: const Icon(Icons.star_outline),
                  title: Text(l10n.ratingTitle),
                  subtitle: Text(l10n.ratingHint),
                  trailing: RatingWidget(
                    rating: rating,
                    compact: true,
                    onChanged: (next) {
                      unawaited(
                        setSongRating(song.id, next, ref).catchError((_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(l10n.ratingUpdateFailed)),
                            );
                          }
                        }),
                      );
                    },
                  ),
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
                        _confirmAndDeleteDownload(context, ref, song.id),
                      );
                    },
                  )
                else
                  ListTile(
                    leading: const Icon(Icons.download_outlined),
                    title: Text(l10n.downloadAction),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_downloadSongFromMenu(context, ref, song.id));
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
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(l10n.downloadSongQueued)),
  );
}

/// Asks for confirmation then deletes the permanently-downloaded file for
/// [songId].
Future<void> _confirmAndDeleteDownload(
  BuildContext context,
  WidgetRef ref,
  String songId,
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
  final track = await cacheDao.getCachedTrack(songId);
  if (track != null) {
    await deleteFileWithSuffixes(track.filePath);
  }
  await cacheDao.removeCachedTrack(songId);
}
