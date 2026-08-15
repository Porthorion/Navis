import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/desktop/desktop_context_menu.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';

/// Shows the shared artist action menu.
///
/// Desktop callers pass the pointer or More-button position as [anchor] so
/// the popup is positioned like a native context menu. Touch callers receive
/// a bottom sheet. The menu intentionally works with an artist ID instead of
/// a particular artist-card model so it can be used from search and similar
/// artist recommendations as well as the local library.
Future<void> showArtistContextMenu(
  BuildContext context,
  WidgetRef ref,
  String artistId, {
  Offset? anchor,
}) async {
  if (anchor != null && isDesktopRuntime) {
    await _showDesktopArtistContextMenu(context, ref, artistId, anchor: anchor);
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => Consumer(
      builder: (context, menuRef, _) {
        final artist = menuRef
            .watch(artistByIdProvider(artistId))
            .asData
            ?.value;
        final songs =
            menuRef.watch(songsByArtistProvider(artistId)).asData?.value ??
            const <SongsTableData>[];
        final isStarred = artist?.starred != null;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.open_in_new_outlined),
                title: Text(
                  AppLocalizations.of(context)!.libraryArtistMenuOpen,
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openArtist(context, menuRef, artistId);
                },
              ),
              ListTile(
                enabled: songs.isNotEmpty,
                leading: const Icon(Icons.play_arrow_outlined),
                title: Text(
                  AppLocalizations.of(context)!.albumDetailPlayAction,
                ),
                onTap: songs.isEmpty
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        _queueArtist(menuRef, songs);
                      },
              ),
              ListTile(
                enabled: songs.isNotEmpty,
                leading: const Icon(Icons.shuffle_outlined),
                title: Text(
                  AppLocalizations.of(context)!.albumDetailShuffleAction,
                ),
                onTap: songs.isEmpty
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        _queueArtist(menuRef, songs, shuffle: true);
                      },
              ),
              ListTile(
                enabled: songs.isNotEmpty,
                leading: const Icon(Icons.queue_music_outlined),
                title: Text(
                  AppLocalizations.of(context)!.libraryAlbumMenuAddToQueue,
                ),
                onTap: songs.isEmpty
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        unawaited(_addArtistToQueue(context, menuRef, songs));
                      },
              ),
              ListTile(
                leading: Icon(
                  isStarred ? Icons.favorite : Icons.favorite_border,
                ),
                title: Text(
                  isStarred
                      ? AppLocalizations.of(context)!.actionLiked
                      : AppLocalizations.of(context)!.actionLike,
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(
                    _toggleArtistStar(context, menuRef, artistId, isStarred),
                  );
                },
              ),
            ],
          ),
        );
      },
    ),
  );
}

enum _ArtistContextAction { open, play, shuffle, addToQueue, toggleLike }

Future<void> _showDesktopArtistContextMenu(
  BuildContext context,
  WidgetRef ref,
  String artistId, {
  required Offset anchor,
}) async {
  final l10n = AppLocalizations.of(context)!;
  var artist = ref.read(artistByIdProvider(artistId)).asData?.value;
  var songs =
      ref.read(songsByArtistProvider(artistId)).asData?.value ??
      const <SongsTableData>[];
  // The library cards do not otherwise need an individual artist's tracks.
  // Resolve the local streams before constructing the popup so its playback
  // actions are immediately usable instead of briefly appearing disabled.
  try {
    artist = await ref.read(artistByIdProvider(artistId).future);
    songs = await ref.read(songsByArtistProvider(artistId).future);
  } on Object {
    // Keep navigation and liking available when local detail data is delayed.
  }
  if (!context.mounted) return;
  final isStarred = artist?.starred != null;
  final action = await showDesktopContextMenu<_ArtistContextAction>(
    context: context,
    anchor: anchor,
    items: <PopupMenuEntry<_ArtistContextAction>>[
      PopupMenuItem<_ArtistContextAction>(
        value: _ArtistContextAction.open,
        child: Text(l10n.libraryArtistMenuOpen),
      ),
      PopupMenuItem<_ArtistContextAction>(
        value: _ArtistContextAction.play,
        enabled: songs.isNotEmpty,
        child: Text(l10n.albumDetailPlayAction),
      ),
      PopupMenuItem<_ArtistContextAction>(
        value: _ArtistContextAction.shuffle,
        enabled: songs.isNotEmpty,
        child: Text(l10n.albumDetailShuffleAction),
      ),
      PopupMenuItem<_ArtistContextAction>(
        value: _ArtistContextAction.addToQueue,
        enabled: songs.isNotEmpty,
        child: Text(l10n.libraryAlbumMenuAddToQueue),
      ),
      const PopupMenuDivider(),
      PopupMenuItem<_ArtistContextAction>(
        value: _ArtistContextAction.toggleLike,
        child: Text(isStarred ? l10n.actionLiked : l10n.actionLike),
      ),
    ],
  );
  if (!context.mounted || action == null) return;

  switch (action) {
    case _ArtistContextAction.open:
      _openArtist(context, ref, artistId);
      return;
    case _ArtistContextAction.play:
      _queueArtist(ref, songs);
      return;
    case _ArtistContextAction.shuffle:
      _queueArtist(ref, songs, shuffle: true);
      return;
    case _ArtistContextAction.addToQueue:
      await _addArtistToQueue(context, ref, songs);
      return;
    case _ArtistContextAction.toggleLike:
      await _toggleArtistStar(context, ref, artistId, isStarred);
      return;
  }
}

void _openArtist(BuildContext context, WidgetRef ref, String artistId) {
  ref
      .read(librarySyncControllerProvider.notifier)
      .registerArtistInteraction(artistId);
  NavService.openArtistDetail(context, ref, artistId);
}

void _queueArtist(
  WidgetRef ref,
  List<SongsTableData> songs, {
  bool shuffle = false,
}) {
  if (songs.isEmpty) return;
  final queue = List<SongsTableData>.of(songs);
  if (shuffle) queue.shuffle(Random());
  ref
      .read(queueProvider.notifier)
      .fireAndForget(
        () => ref.read(queueProvider.notifier).replaceWithTableData(queue),
        label: 'replace',
      );
}

Future<void> _addArtistToQueue(
  BuildContext context,
  WidgetRef ref,
  List<SongsTableData> songs,
) async {
  if (songs.isEmpty) return;
  try {
    for (final song in songs) {
      await ref.read(queueProvider.notifier).add(song.id);
    }
  } on Object {
    if (!context.mounted) return;
    showAppNotice(
      context,
      message: AppLocalizations.of(context)!.playbackActionFailed,
      level: AppNoticeLevel.error,
    );
    return;
  }
  if (!context.mounted) return;
  showAppNotice(
    context,
    message: AppLocalizations.of(context)!.libraryArtistAddedToQueue,
    level: AppNoticeLevel.success,
  );
}

Future<void> _toggleArtistStar(
  BuildContext context,
  WidgetRef ref,
  String artistId,
  bool isStarred,
) async {
  final dao = ref.read(navisDatabaseProvider).libraryDao;
  await dao.updateArtistStarred(
    artistId,
    isStarred ? null : DateTime.now(),
  );
  final api = ref.read(subsonicApiProvider);
  if (api == null) return;
  try {
    if (isStarred) {
      await api.unstar(artistId);
    } else {
      await api.star(artistId);
    }
  } on SubsonicConnectionException {
    await ref
        .read(navisDatabaseProvider)
        .starSyncDao
        .queueStarAction(
          itemId: artistId,
          itemType: 'artist',
          action: isStarred ? 'unstar' : 'star',
        );
  } on Object {
    await dao.updateArtistStarred(
      artistId,
      isStarred ? DateTime.now() : null,
    );
    if (!context.mounted) return;
    showAppNotice(
      context,
      message: AppLocalizations.of(context)!.albumDetailStarFailure,
      level: AppNoticeLevel.error,
    );
  }
}
