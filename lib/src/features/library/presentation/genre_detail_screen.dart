import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/album_context_menu.dart';
import 'package:navis/src/common_widgets/album_download_badge.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/desktop_song_actions.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/song_context_menu.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/routing/desktop_layout.dart';

class GenreDetailScreen extends ConsumerWidget {
  const GenreDetailScreen({required this.encodedGenre, super.key});

  final String encodedGenre;

  String get genreName => utf8.decode(base64Url.decode(encodedGenre));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final albums = ref.watch(albumsByGenreProvider(genreName));
    final songs = ref.watch(songsByGenreProvider(genreName));
    Future<void> refresh() {
      return ref.read(librarySyncControllerProvider.notifier).syncNow();
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.libraryGenreDetailTitle(genreName)),
          bottom: TabBar(
            tabs: <Widget>[
              Tab(text: l10n.libraryGenreAlbumsTab),
              Tab(text: l10n.libraryGenreSongsTab),
            ],
          ),
        ),
        body: TabBarView(
          children: <Widget>[
            RefreshIndicator(
              onRefresh: refresh,
              child: albums.when(
                data: (items) {
                  if (items.isEmpty) {
                    return ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: <Widget>[
                        EmptyState(
                          title: l10n.libraryGenreAlbumsEmptyTitle,
                          subtitle: l10n.libraryGenreAlbumsEmptySubtitle,
                          icon: Icons.album_outlined,
                        ),
                      ],
                    );
                  }
                  return ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final album = items[index];
                      final heroTag = buildCoverArtHeroTag(
                        coverArtId: album.coverArt,
                        context: 'genre_album',
                        entityId: album.id,
                      );
                      return AlbumCard(
                        album: album,
                        heroTag: heroTag,
                        badge: AlbumDownloadBadge(albumId: album.id),
                        onTap: () => NavService.openAlbumDetail(
                          context,
                          ref,
                          album.id,
                          heroTag: heroTag,
                        ),
                        onLongPress: () =>
                            showAlbumContextMenu(context, ref, album.id),
                        onSecondaryTapDown: (details) => showAlbumContextMenu(
                          context,
                          ref,
                          album.id,
                          anchor: details.globalPosition,
                        ),
                      );
                    },
                  );
                },
                loading: () => const ShimmerListPage(count: 6, leadingSize: 56),
                error: (error, _) => ErrorState(
                  title: l10n.libraryGenreLoadErrorTitle,
                  onRetry: () =>
                      ref.invalidate(albumsByGenreProvider(genreName)),
                ),
              ),
            ),
            RefreshIndicator(
              onRefresh: refresh,
              child: songs.when(
                data: (items) {
                  if (items.isEmpty) {
                    return ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: <Widget>[
                        EmptyState(
                          title: l10n.libraryGenreSongsEmptyTitle,
                          subtitle: l10n.libraryGenreSongsEmptySubtitle,
                          icon: Icons.music_note_outlined,
                        ),
                      ],
                    );
                  }
                  return ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final song = items[index];
                      return TrackListTile(
                        song: song,
                        onTap: () {
                          ref.read(queueProvider.notifier).replaceWithTableData(
                            <SongsTableData>[song],
                            autoPlay: true,
                          ).ignore();
                        },
                        onLongPress: () =>
                            showSongContextMenu(context, ref, song),
                        trailing: isDesktopRuntime
                            ? DesktopSongActions(
                                song: song,
                                keyPrefix: 'genre-song',
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  SongDownloadStatusIcon(
                                    songId: song.id,
                                    onDownload: () => unawaited(() async {
                                      final choice =
                                          await showDownloadQualitySheet(
                                            context,
                                          );
                                      if (choice == null || !context.mounted)
                                        return;
                                      unawaited(
                                        ref
                                            .read(downloadServiceProvider)
                                            .enqueueSong(
                                              song.id,
                                              quality: choice.quality,
                                              format: choice.format,
                                            ),
                                      );
                                      if (!context.mounted) return;
                                      showAppNotice(
                                        context,
                                        message: l10n.downloadSongQueued,
                                        level: AppNoticeLevel.success,
                                      );
                                    }()),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.more_vert),
                                    onPressed: () =>
                                        showSongContextMenu(context, ref, song),
                                  ),
                                ],
                              ),
                      );
                    },
                  );
                },
                loading: () => const ShimmerListPage(count: 8),
                error: (error, _) => ErrorState(
                  title: l10n.libraryGenreLoadErrorTitle,
                  onRetry: () =>
                      ref.invalidate(songsByGenreProvider(genreName)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
