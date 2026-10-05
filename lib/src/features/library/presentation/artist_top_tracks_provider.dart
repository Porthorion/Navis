import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/data/artist_top_track_match_store.dart';
import 'package:navis/src/features/library/data/artist_top_track_resolver.dart';
import 'package:navis/src/features/library/data/artist_top_track_sources.dart';
import 'package:navis/src/features/library/domain/artist_top_track.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/sync_diagnostics_overrides.dart';

export 'package:navis/src/features/library/data/artist_top_track_resolver.dart'
    show artistTopTrackMatchQuery, pickBestArtistTopTrackMatch;
export 'package:navis/src/features/library/domain/artist_top_track.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Most top songs in the "This Is" playlist.
const int kArtistTopTracksPlaylistMax = kArtistTopTrackSeedMax;

/// Top songs resolved for the artist page's Top Tracks section.
const int kArtistTopTracksSectionMax = 10;

/// Minimum tracks visible before "Show more".
const int kArtistTopTracksCollapsed = 5;

/// Span recorded on `IntegrationCallRecorder` when the seeds are loaded.
const String kTopSongsSourceFetchSpan = 'topSongs.sourceFetch';

/// Identifies an artist's top songs: the library artist id (for its
/// `ext-deezer-artist-<id>` shortcut and the remembered matches) and its name.
typedef ArtistTopTracksKey = ({String artistId, String name});

// ---------------------------------------------------------------------------
// Infrastructure
// ---------------------------------------------------------------------------

/// Whether any top-songs source is allowed (Deezer, then Last.fm). When false
/// the Top Tracks section is hidden and "This Is" the artist becomes a shuffle
/// of the artist's library songs.
final artistTopSongsAllowedProvider = Provider<bool>((ref) {
  return ref.watch(
    integrationPolicyProvider.select(
      (policy) =>
          policy.allows(IntegrationFeature.deezerTopSongs) ||
          policy.allows(IntegrationFeature.lastFmTopSongs),
    ),
  );
});

final artistTopTrackSourcesProvider = Provider<ArtistTopTrackSources>((ref) {
  return ArtistTopTrackSources(
    cache: ref.watch(integrationJsonCacheProvider),
    deezer: ref.watch(deezerApiClientProvider),
    deezerArtists: ref.watch(deezerArtistResolverProvider),
    lastFm: ref.watch(lastFmApiClientProvider),
  );
});

/// Rebuilt for each server account; the old store drops its pending saves.
final artistTopTrackMatchStoreProvider = Provider<ArtistTopTrackMatchStore>((
  ref,
) {
  final store = ArtistTopTrackMatchStore(
    cache: ref.watch(integrationJsonCacheProvider),
    accountScope: ref.watch(integrationAccountScopeProvider) ?? 'signed-out',
  );
  ref.onDispose(store.invalidate);
  return store;
});

/// Kept for the app's lifetime so a search the section started is shared
/// with the "This Is" page.
final artistTopTrackResolverProvider = Provider<ArtistTopTrackResolver>((ref) {
  return ArtistTopTrackResolver(
    libraryDao: ref.watch(navisDatabaseProvider).libraryDao,
    api: ref.watch(subsonicApiProvider),
    store: ref.watch(artistTopTrackMatchStoreProvider),
    recorder: ref.watch(integrationCallRecorderProvider),
  );
});

/// Forgets remembered top-song matches after every library sync that
/// changed the library, fully or partly, so the next visit matches against
/// the synced library, then refreshes the other library-relative integration
/// results (Deezer artist ids, New Releases, Trending). Watched by the app
/// shell.
final artistTopTrackMatchSyncBridgeProvider = Provider<void>((ref) {
  ref.listen<LibrarySyncState>(librarySyncControllerProvider, (previous, next) {
    final finished =
        next.status == LibrarySyncStatus.succeeded ||
        next.status == LibrarySyncStatus.partial;
    if (!finished || previous?.status == next.status) return;
    final store = ref.read(artistTopTrackMatchStoreProvider);
    ref.read(artistTopTrackResolverProvider).forgetSearches();
    unawaited(
      store.clear().then((_) {
        // Deferred past the clear, and past any widget build that delivered
        // the sync transition.
        if (!ref.mounted) return;
        ref.read(refreshIntegrationLibraryResultsProvider)();
        ref
          ..invalidate(artistTopTracksProvider)
          ..invalidate(artistTopTracksPlaylistProvider);
      }),
    );
  });
});

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// An artist's top songs (up to [kArtistTopTracksPlaylistMax]) from the
/// first allowed source: Deezer, then Last.fm, then none.
///
/// Kept for 5 minutes after the last listener leaves, so scrolling the
/// section in and out of view does not fetch again (issue #31). The sources
/// cache their results on disk for 24 hours.
final artistTopTrackSeedsProvider = FutureProvider.autoDispose
    .family<List<ArtistTopTrackSeed>, ArtistTopTracksKey>((ref, key) async {
      Timer? disposeTimer;
      final keepAliveLink = ref.keepAlive();
      ref.onCancel(() {
        disposeTimer = Timer(const Duration(minutes: 5), keepAliveLink.close);
      });
      ref.onResume(() {
        disposeTimer?.cancel();
        disposeTimer = null;
      });
      ref.onDispose(() => disposeTimer?.cancel());

      final usePresentationFixture = ref.watch(
        syncDiagnosticsOverridesProvider.select(
          (overrides) => overrides.artistTopTracksPresentationFixture,
        ),
      );
      if (usePresentationFixture) return _presentationFixtureSeeds;

      final (:deezerAllowed, :lastFmAllowed) = ref.watch(
        integrationPolicyProvider.select(
          (policy) => (
            deezerAllowed: policy.allows(IntegrationFeature.deezerTopSongs),
            lastFmAllowed: policy.allows(IntegrationFeature.lastFmTopSongs),
          ),
        ),
      );
      if (!deezerAllowed && !lastFmAllowed) return const [];
      if (key.name.trim().isEmpty) return const [];

      final sources = ref.watch(artistTopTrackSourcesProvider);
      final libraryDao = ref.watch(navisDatabaseProvider).libraryDao;
      final recorder = ref.read(integrationCallRecorderProvider);
      final cancelToken = CancelToken();
      ref.onDispose(cancelToken.cancel);

      final timer = Stopwatch()..start();
      final load = await sources.load(
        artistId: key.artistId,
        artistName: key.name,
        deezerAllowed: deezerAllowed,
        lastFmAllowed: lastFmAllowed,
        readLibraryAlbumTitles: () async {
          final buckets = await libraryDao
              .watchArtistAlbumBuckets(key.artistId)
              .first;
          return buckets.primaryAlbums.map((album) => album.name);
        },
        cancelToken: cancelToken,
        readLastFmAllowed: () =>
            ref.mounted &&
            ref
                .read(integrationPolicyProvider)
                .allows(IntegrationFeature.lastFmTopSongs),
      );
      recorder.span(kTopSongsSourceFetchSpan, <String, int>{
        'seeds': load.seeds.length,
        'cacheHit': load.cacheHit ? 1 : 0,
        'deezer': load.seeds.firstOrNull?.source == ArtistTopTrackSource.deezer
            ? 1
            : 0,
        'top': load.fromTop,
        'searchFill': load.fromSearch,
        'lastFm': load.fromLastFm,
      }, timer.elapsed);
      return load.seeds;
    });

/// The artist page's Top Tracks: the first [kArtistTopTracksSectionMax]
/// songs only, matched to the library.
///
/// Emits after the local pass, when server searches follow, and again at the
/// end. Leaving the page cancels the searches still running.
final artistTopTracksProvider = StreamProvider.autoDispose
    .family<List<ResolvedArtistTopTrack>, ArtistTopTracksKey>((ref, key) {
      return _resolveTopTracks(ref, key, limit: kArtistTopTracksSectionMax);
    });

/// The "This Is" page of an artist: every top song, matched to the library. Only
/// the page itself watches this; the artist page never resolves all 50.
final artistTopTracksPlaylistProvider = FutureProvider.autoDispose
    .family<List<ResolvedArtistTopTrack>, ArtistTopTracksKey>((ref, key) {
      return _resolveTopTracks(ref, key).last;
    });

Stream<List<ResolvedArtistTopTrack>> _resolveTopTracks(
  Ref ref,
  ArtistTopTracksKey key, {
  int? limit,
}) async* {
  final resolver = ref.watch(artistTopTrackResolverProvider);
  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);
  final seeds = await ref.watch(artistTopTrackSeedsProvider(key).future);
  yield* resolver.resolve(
    artistId: key.artistId,
    seeds: limit == null ? seeds : seeds.take(limit).toList(growable: false),
    cancelToken: cancelToken,
  );
}

const _presentationFixtureSeeds = <ArtistTopTrackSeed>[
  ArtistTopTrackSeed(
    rank: 1,
    title: 'North Star',
    artist: 'Navis demo artist',
    listeners: 482910,
    source: ArtistTopTrackSource.lastFm,
  ),
  ArtistTopTrackSeed(
    rank: 2,
    title: 'Afterglow',
    artist: 'Navis demo artist',
    listeners: 318745,
    source: ArtistTopTrackSource.lastFm,
  ),
  ArtistTopTrackSeed(
    rank: 3,
    title: 'Blue Hour',
    artist: 'Navis demo artist',
    listeners: 245180,
    source: ArtistTopTrackSource.lastFm,
  ),
  ArtistTopTrackSeed(
    rank: 4,
    title: 'Slow Motion',
    artist: 'Navis demo artist',
    listeners: 198352,
    source: ArtistTopTrackSource.lastFm,
  ),
];
