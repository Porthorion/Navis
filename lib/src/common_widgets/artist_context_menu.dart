import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/desktop/desktop_context_menu.dart';
import 'package:navis/src/common_widgets/artist_playback_action.dart';
import 'package:navis/src/features/library/presentation/artist_playback_controller.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
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

  final container = ProviderScope.containerOf(context, listen: false);
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => Consumer(
      builder: (context, menuRef, _) {
        final artist = menuRef
            .watch(artistByIdProvider(artistId))
            .asData
            ?.value;
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
                  _openArtist(context, menuRef, artistId, name: artist?.name);
                },
              ),
              ListTile(
                leading: const Icon(Icons.play_arrow_outlined),
                title: Text(
                  AppLocalizations.of(context)!.albumDetailPlayAction,
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(
                    startArtistPlayback(
                      container,
                      artistId,
                      ArtistPlaybackAction.play,
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.shuffle_outlined),
                title: Text(
                  AppLocalizations.of(context)!.albumDetailShuffleAction,
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(
                    startArtistPlayback(
                      container,
                      artistId,
                      ArtistPlaybackAction.shuffle,
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_music_outlined),
                title: Text(
                  AppLocalizations.of(context)!.libraryAlbumMenuAddToQueue,
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(
                    startArtistPlayback(
                      container,
                      artistId,
                      ArtistPlaybackAction.add,
                    ),
                  );
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
  final artist = ref.read(artistByIdProvider(artistId)).asData?.value;
  final container = ProviderScope.containerOf(context, listen: false);
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
        child: Text(l10n.albumDetailPlayAction),
      ),
      PopupMenuItem<_ArtistContextAction>(
        value: _ArtistContextAction.shuffle,
        child: Text(l10n.albumDetailShuffleAction),
      ),
      PopupMenuItem<_ArtistContextAction>(
        value: _ArtistContextAction.addToQueue,
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
      _openArtist(context, ref, artistId, name: artist?.name);
      return;
    case _ArtistContextAction.play:
      await startArtistPlayback(container, artistId, ArtistPlaybackAction.play);
      return;
    case _ArtistContextAction.shuffle:
      await startArtistPlayback(
        container,
        artistId,
        ArtistPlaybackAction.shuffle,
      );
      return;
    case _ArtistContextAction.addToQueue:
      await startArtistPlayback(container, artistId, ArtistPlaybackAction.add);
      return;
    case _ArtistContextAction.toggleLike:
      await _toggleArtistStar(context, ref, artistId, isStarred);
      return;
  }
}

void _openArtist(
  BuildContext context,
  WidgetRef ref,
  String artistId, {
  String? name,
}) {
  ref
      .read(librarySyncControllerProvider.notifier)
      .registerArtistInteraction(artistId);
  NavService.openArtistDetail(context, ref, artistId, name: name);
}

Future<void> _toggleArtistStar(
  BuildContext context,
  WidgetRef ref,
  String artistId,
  bool isStarred,
) async {
  try {
    await ref
        .read(navisDatabaseProvider)
        .starSyncDao
        .setStarred(itemId: artistId, itemType: 'artist', liked: !isStarred);
  } on Object {
    if (!context.mounted) return;
    showAppNotice(
      context,
      message: AppLocalizations.of(context)!.albumDetailStarFailure,
      level: AppNoticeLevel.error,
    );
  }
}
