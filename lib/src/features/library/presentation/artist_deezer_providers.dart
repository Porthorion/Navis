import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:navis/src/api/models/deezer_models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/domain/missing_albums.dart';
import 'package:navis/src/features/library/domain/similar_artist_entry.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Identifies the artist of an artist page: the library id (for its
/// `ext-deezer-artist-<id>` shortcut) and the name. The same record type as
/// the top-songs key.
typedef ArtistPageKey = ({String artistId, String name});

/// The Deezer artist of an artist page, shared by the page's Deezer
/// sections. Only watched behind a feature switch, so it never runs while
/// every artist-page Deezer feature is off.
final artistDeezerIdProvider = FutureProvider.autoDispose
    .family<int?, ArtistPageKey>((ref, key) async {
      if (key.name.trim().isEmpty) return null;
      final resolver = ref.watch(deezerArtistResolverProvider);
      final libraryDao = ref.watch(navisDatabaseProvider).libraryDao;
      final cancelToken = CancelToken();
      ref.onDispose(cancelToken.cancel);
      return await resolver.resolve(
        artistId: key.artistId,
        name: key.name,
        readLibraryAlbumTitles: () async {
          final buckets = await libraryDao
              .watchArtistAlbumBuckets(key.artistId)
              .first;
          return buckets.primaryAlbums.map((album) => album.name);
        },
        cancelToken: cancelToken,
      );
    });

/// The artist's Deezer photo and fan count (`deezer.artistImages`), or null
/// when the switch is off or Deezer has no such artist.
final artistDeezerDetailsProvider = FutureProvider.autoDispose
    .family<DeezerArtist?, ArtistPageKey>((ref, key) async {
      if (!_allows(ref, IntegrationFeature.deezerArtistImages)) {
        return null;
      }
      final deezerId = await ref.watch(artistDeezerIdProvider(key).future);
      if (deezerId == null) return null;
      final cancelToken = CancelToken();
      ref.onDispose(cancelToken.cancel);
      return await ref
          .watch(deezerCatalogProvider)
          .artist(deezerId, cancelToken: cancelToken);
    });

/// "Fans also like" (`deezer.similarArtists`): Deezer's related artists, the
/// ones in the library first. Empty when the switch is off or Deezer has
/// none, and the page then shows the server's similar artists.
final artistFansAlsoLikeProvider = FutureProvider.autoDispose
    .family<List<SimilarArtistEntry>, ArtistPageKey>((ref, key) async {
      if (!_allows(ref, IntegrationFeature.deezerSimilarArtists)) {
        return const <SimilarArtistEntry>[];
      }
      final deezerId = await ref.watch(artistDeezerIdProvider(key).future);
      if (deezerId == null) return const <SimilarArtistEntry>[];
      final cancelToken = CancelToken();
      ref.onDispose(cancelToken.cancel);
      final related = await ref
          .watch(deezerCatalogProvider)
          .relatedArtists(deezerId, cancelToken: cancelToken);
      if (related.isEmpty) return const <SimilarArtistEntry>[];
      final libraryByName = await ref
          .watch(navisDatabaseProvider)
          .libraryDao
          .findArtistsByNormalizedNames(related.map((artist) => artist.name));
      return fansAlsoLikeEntries(
        related: related,
        libraryByName: libraryByName,
        currentArtistId: key.artistId,
        currentArtistName: key.name,
      );
    });

/// Every Deezer release of the artist (`deezer.missingAlbums`); empty when
/// the switch is off or Deezer has no such artist.
final artistDeezerAlbumsProvider = FutureProvider.autoDispose
    .family<List<DeezerAlbum>, ArtistPageKey>((ref, key) async {
      if (!_allows(ref, IntegrationFeature.deezerMissingAlbums)) {
        return const <DeezerAlbum>[];
      }
      final deezerId = await ref.watch(artistDeezerIdProvider(key).future);
      if (deezerId == null) return const <DeezerAlbum>[];
      final cancelToken = CancelToken();
      ref.onDispose(cancelToken.cancel);
      return await ref
          .watch(deezerCatalogProvider)
          .artistAlbums(deezerId, cancelToken: cancelToken);
    });

/// The artist's Deezer albums and EPs that the library lacks (see
/// [missingDeezerAlbums]).
///
/// Empty, and Deezer is not asked, while the artist's library albums load or
/// when the server already has remote albums for the artist (a remote
/// catalogue such as Octo-Fiesta's always wins). Empty while Deezer loads or
/// fails, so the section only ever appears complete.
final artistMissingAlbumsProvider = Provider.autoDispose
    .family<List<DeezerAlbum>, ArtistPageKey>((ref, key) {
      final artist = ref.watch(artistByIdProvider(key.artistId)).value;
      final sections = ref.watch(artistAlbumSectionsProvider(key.artistId));
      final library = sections.value;
      if (artist == null || artist.isExternal || library == null) {
        return const <DeezerAlbum>[];
      }
      if (library.albums.any((album) => album.isExternal)) {
        return const <DeezerAlbum>[];
      }
      final deezerAlbums = ref.watch(artistDeezerAlbumsProvider(key)).value;
      if (deezerAlbums == null || deezerAlbums.isEmpty) {
        return const <DeezerAlbum>[];
      }
      return missingDeezerAlbums(
        deezerAlbums: deezerAlbums,
        libraryAlbums: <AlbumsTableData>[
          ...library.albums,
          ...library.featuredIn,
        ],
      );
    });

/// Watches whether the policy allows [feature].
bool _allows(Ref ref, IntegrationFeature feature) => ref.watch(
  integrationPolicyProvider.select((policy) => policy.allows(feature)),
);
