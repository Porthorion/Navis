import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/song_cache_badge.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
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
            albums.when(
              data: (items) {
                if (items.isEmpty) {
                  return EmptyState(
                    title: l10n.libraryGenreAlbumsEmptyTitle,
                    subtitle: l10n.libraryGenreAlbumsEmptySubtitle,
                    icon: Icons.album_outlined,
                  );
                }
                return ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final album = items[index];
                    return AlbumCard(
                      album: album,
                      onTap: () => context.go('/library/albums/${album.id}'),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => ErrorState(
                title: l10n.libraryGenreLoadErrorTitle,
                message: error.toString(),
                retryLabel: l10n.commonRetry,
              ),
            ),
            songs.when(
              data: (items) {
                if (items.isEmpty) {
                  return EmptyState(
                    title: l10n.libraryGenreSongsEmptyTitle,
                    subtitle: l10n.libraryGenreSongsEmptySubtitle,
                    icon: Icons.music_note_outlined,
                  );
                }
                return ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    return TrackListTile(
                      song: items[index],
                      badge: SongCacheBadge(songId: items[index].id),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => ErrorState(
                title: l10n.libraryGenreLoadErrorTitle,
                message: error.toString(),
                retryLabel: l10n.commonRetry,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
