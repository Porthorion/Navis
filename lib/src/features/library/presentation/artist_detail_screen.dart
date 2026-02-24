import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/star_button.dart';
import 'package:navis/src/providers/app_providers.dart';

class ArtistDetailScreen extends ConsumerStatefulWidget {
  const ArtistDetailScreen({required this.artistId, super.key});

  final String artistId;

  @override
  ConsumerState<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends ConsumerState<ArtistDetailScreen> {
  bool _isStarred = false;
  bool _isStarring = false;

  Future<void> _toggleStar({required bool isStarred}) async {
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;
    setState(() => _isStarring = true);
    try {
      if (isStarred) {
        await api.unstar(widget.artistId);
      } else {
        await api.star(widget.artistId);
      }
      if (mounted) setState(() => _isStarred = !isStarred);
      // Persist star change to local DB so library views update reactively.
      final dao = ref.read(navisDatabaseProvider).libraryDao;
      await dao.updateArtistStarred(
        widget.artistId,
        isStarred ? null : DateTime.now(),
      );
    } on Object catch (error, stackTrace) {
      debugPrint('Star toggle failed: $error\n$stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.albumDetailStarFailure,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isStarring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final artist = ref.watch(artistByIdProvider(widget.artistId));
    final albums = ref.watch(albumsByArtistProvider(widget.artistId));
    final artistInfo = ref.watch(artistInfoProvider(widget.artistId));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.artistDetailTitle)),
      body: artist.when(
        data: (artistData) {
          if (artistData == null) {
            return EmptyState(
              title: l10n.artistDetailNotFoundTitle,
              subtitle: l10n.artistDetailNotFoundSubtitle,
              icon: Icons.person_off_outlined,
            );
          }

          final isStarred = _isStarred || artistData.starred != null;

          return ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              // ── Artist image header ─────────────────────────────────────
              artistInfo.when(
                data: (info) {
                  final url =
                      info?.largeImageUrl ?? info?.mediumImageUrl ?? '';
                  if (url.isEmpty) return const SizedBox.shrink();
                  return _ArtistImageHeader(imageUrl: url);
                },
                loading: () => const SizedBox.shrink(),
                error: (_, _) => const SizedBox.shrink(),
              ),
              // ── Name + star ─────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        artistData.name,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    StarButton(
                      isStarred: isStarred,
                      onPressed: _isStarring
                          ? null
                          : () => _toggleStar(isStarred: isStarred),
                      compact: true,
                      tooltip: l10n.albumDetailStarAction,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  l10n.artistDetailAlbumCount(artistData.albumCount ?? 0),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              // ── Bio + similar artists ───────────────────────────────────
              artistInfo.when(
                data: (info) {
                  if (info == null) {
                    return const SizedBox.shrink();
                  }
                  return _ArtistInfoSection(info: info);
                },
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
                error: (_, _) => const SizedBox.shrink(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  l10n.artistDetailAlbumsSection,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              albums.when(
                data: (items) {
                  if (items.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: EmptyState(
                        title: l10n.artistDetailAlbumsEmptyTitle,
                        subtitle: l10n.artistDetailAlbumsEmptySubtitle,
                        icon: Icons.album_outlined,
                      ),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    child: GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: items.length,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            childAspectRatio: 1,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                      itemBuilder: (context, index) {
                        final album = items[index];
                        return RepaintBoundary(
                          child: AlbumCard(
                            album: album,
                            size: AlbumCardSize.library,
                            onTap: () =>
                                context.go('/library/albums/${album.id}'),
                          ),
                        );
                      },
                    ),
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => ErrorState(
                  title: l10n.artistDetailAlbumsErrorTitle,
                  message: error.toString(),
                  onRetry: () =>
                      ref.invalidate(albumsByArtistProvider(widget.artistId)),
                ),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorState(
          title: l10n.artistDetailLoadErrorTitle,
          message: error.toString(),
          onRetry: () => ref.invalidate(artistByIdProvider(widget.artistId)),
        ),
      ),
    );
  }
}

/// Full-width header image shown at the top of the artist detail page when
/// the artist has a photo from the Last.fm / MusicBrainz metadata.
class _ArtistImageHeader extends StatelessWidget {
  const _ArtistImageHeader({required this.imageUrl});

  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 240,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Image.network(
            imageUrl,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          // Gradient overlay — fades to scaffold background at the bottom
          // so the artist name blends in naturally.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Color(0x00000000),
                  Color(0xCC000000),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtistInfoSection extends StatelessWidget {
  const _ArtistInfoSection({required this.info});

  final ArtistInfo info;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if ((info.biography == null || info.biography!.trim().isEmpty) &&
        info.similarArtists.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (info.biography != null &&
              info.biography!.trim().isNotEmpty) ...<Widget>[
            Text(
              l10n.artistDetailBioSection,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(info.biography!),
            const SizedBox(height: 12),
          ],
          if (info.similarArtists.isNotEmpty) ...<Widget>[
            Text(
              l10n.artistDetailSimilarSection,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                for (final artist in info.similarArtists)
                  ActionChip(
                    label: Text(artist.name),
                    onPressed: () =>
                        context.go('/library/artists/${artist.id}'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
