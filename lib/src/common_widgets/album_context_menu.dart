import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Shows a bottom sheet context menu for an album identified by [albumId].
///
/// Actions: Open, Play, Add to Queue, Like/Unlike, Download.
Future<void> showAlbumContextMenu(
  BuildContext context,
  WidgetRef ref,
  String albumId,
) async {
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) {
      return Consumer(
        builder: (ctx, menuRef, _) {
          final l10n = AppLocalizations.of(context)!;
          final albumAsync = menuRef.watch(albumProvider(albumId));
          final album = albumAsync.asData?.value;
          final songs = album?.songs ?? const [];
          final isStarred = album?.album.starred != null;

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
                    context.push('/library/albums/$albumId');
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
                          final songIds = songs
                              .map((s) => s.id)
                              .toList(growable: false);
                          unawaited(
                            ref.read(queueProvider.notifier).replace(songIds),
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
                            for (final song in songs) {
                              await ref
                                  .read(queueProvider.notifier)
                                  .add(song.id);
                            }
                          }());
                        },
                ),
                ListTile(
                  leading: Icon(
                    isStarred ? Icons.favorite : Icons.favorite_border_outlined,
                  ),
                  title: Text(
                    isStarred
                        ? l10n.libraryAlbumMenuUnlike
                        : l10n.libraryAlbumMenuLike,
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_toggleAlbumStar(ref, albumId, isStarred));
                  },
                ),
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
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(l10n.downloadAlbumQueued(count))),
  );
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
