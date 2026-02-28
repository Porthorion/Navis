import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/album_download_badge.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/song_cache_badge.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

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
      return ref
          .read(librarySyncControllerProvider.notifier)
          .syncNow(preferIncremental: true);
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
                      return AlbumCard(
                        album: album,
                        badge: AlbumDownloadBadge(albumId: album.id),
                        onTap: () => context.go('/library/albums/${album.id}'),
                      );
                    },
                  );
                },
                loading: () => const ShimmerListPage(count: 6, leadingSize: 56),
                error: (error, _) => ErrorState(
                  title: l10n.libraryGenreLoadErrorTitle,
                  message: error.toString(),
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
                      return TrackListTile(
                        song: items[index],
                        badge: SongCacheBadge(songId: items[index].id),
                      );
                    },
                  );
                },
                loading: () => const ShimmerListPage(count: 8),
                error: (error, _) => ErrorState(
                  title: l10n.libraryGenreLoadErrorTitle,
                  message: error.toString(),
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
