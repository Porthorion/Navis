import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/domain/new_releases.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/data/artist_top_track_match_store.dart';
import 'package:navis/src/features/library/data/artist_top_track_resolver.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/catalog_source.dart';

/// Library artists whose releases Home's New releases checks.
const int kNewReleasesCandidateArtists = 30;

/// Artists checked at once; the Deezer limiter still paces the requests.
const int _kNewReleasesWorkers = 3;

/// Span name on `IntegrationCallRecorder`, for the diagnostics endpoint.
const String kHomeNewReleasesSpan = 'home.newReleases';

/// The fewest playable chart songs Trending Now needs to join the You Might
/// Like hero.
const int kTrendingMinimumPlayable = 8;

/// Chart songs searched on the server at once while Home refreshes by
/// itself, and after a pull to refresh.
const int _kTrendingSearchWorkers = 2;
const int _kTrendingManualSearchWorkers = 6;

/// Finished searches between the updates a pull to refresh shows.
const int _kTrendingProgressEvery = 6;

/// The key Trending's remembered matches are stored under.
const String kTrendingMatchKey = 'deezer-chart';

/// Trending's remembered matches: their own namespace, which a library sync
/// does not clear (every resolve checks the library again), kept two weeks
/// so a remote match outlives its daily server recheck.
const String kTrendingMatchNamespace = 'trending.matches';
const Duration kTrendingMatchKeepFor = Duration(days: 14);

/// Span names on `IntegrationCallRecorder`: `home.trending`, and the
/// matcher's `trending.localMatch` and `trending.serverMatch`.
const String kHomeTrendingSpan = 'home.trending';
const String kTrendingMatchSpanPrefix = 'trending';

/// How long Home waits, once no library sync is running, before its Deezer
/// sections ask Deezer, so the first screen and the sync come first.
final homeDeezerStartupDelayProvider = Provider<Duration>(
  (_) => const Duration(seconds: 3),
);

/// Whether a library sync is running, for [homeDeezerIdleProvider].
final homeDeezerSyncRunningProvider = Provider<bool>((ref) {
  try {
    return ref.watch(
      librarySyncControllerProvider.select((state) => state.isRunning),
    );
  } on Object {
    return false;
  }
});

/// Completes once Home is idle: no library sync is running and the startup
/// delay has passed. Kept for the session, so a pull to refresh or a switch
/// turned back on does not wait again.
final homeDeezerIdleProvider = FutureProvider<void>((ref) async {
  Future<void> syncFinished() async {
    while (ref.mounted && ref.read(homeDeezerSyncRunningProvider)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  await syncFinished();
  final delay = ref.read(homeDeezerStartupDelayProvider);
  if (delay > Duration.zero && ref.mounted) {
    await Future<void>.delayed(delay);
    // A sync that started during the delay goes first too.
    await syncFinished();
  }
});

/// Today, for the New releases window; overridden by tests.
final homeNewReleasesClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

/// New releases from your artists (`deezer.newReleases`): releases from the
/// last 30 days by the [kNewReleasesCandidateArtists] library artists played
/// most (liked ones first among equals), newest first. With fewer played or
/// liked artists than that, library artists fill the rest, ranked by liked
/// albums, then songs, then albums.
///
/// Empty, without asking Deezer, while the switch is off or when no library
/// artist has songs. Otherwise it waits for
/// [homeDeezerIdleProvider], then reads each artist's Deezer id (resolver,
/// cached 30 days) and first releases (cached 24 hours) through the
/// limiter, as background requests that yield to the artist page and other
/// foreground Deezer requests. An artist Deezer does not know, or whose
/// request fails, is skipped. The provider lives for the session; invalidating it (pull to
/// refresh) or turning the switch off cancels its requests.
final homeNewReleasesProvider = FutureProvider<List<HomeNewRelease>>((
  ref,
) async {
  final scope = ref.watch(integrationAccountScopeProvider);
  final allowed = ref.watch(
    integrationPolicyProvider.select(
      (policy) => policy.allows(IntegrationFeature.deezerNewReleases),
    ),
  );
  if (!allowed || scope == null) return const <HomeNewRelease>[];
  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);
  final resolver = ref.watch(deezerArtistResolverProvider);
  final catalog = ref.watch(deezerCatalogProvider);
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  final played = await dao.getTopPlayedArtists(
    limit: kNewReleasesCandidateArtists,
  );
  if (!ref.mounted) return const <HomeNewRelease>[];
  // Little play history (a new account): fill up with the library's own
  // favourites, ranked after every played artist.
  final artists = <ArtistsTableData>[
    ...played,
    ...await dao.getArtistsByLibraryWeight(
      limit: kNewReleasesCandidateArtists - played.length,
      excludeIds: {for (final artist in played) artist.id},
    ),
  ];
  if (!ref.mounted || artists.isEmpty) return const <HomeNewRelease>[];
  await ref.watch(homeDeezerIdleProvider.future);
  if (!ref.mounted) return const <HomeNewRelease>[];

  final timer = Stopwatch()..start();
  final byArtist = List<ArtistReleases?>.filled(artists.length, null);
  var next = 0;
  var resolved = 0;
  var failed = 0;
  Future<void> worker() async {
    while (next < artists.length && !cancelToken.isCancelled) {
      final index = next++;
      final artist = artists[index];
      List<AlbumsTableData>? libraryAlbums;
      Future<List<AlbumsTableData>> readLibraryAlbums() async =>
          libraryAlbums ??= await dao.getAlbumsByArtist(artist.id);
      try {
        final deezerId = await resolver.resolve(
          artistId: artist.id,
          name: artist.name,
          readLibraryAlbumTitles: () async =>
              (await readLibraryAlbums()).map((album) => album.name),
          cancelToken: cancelToken,
          background: true,
        );
        if (deezerId == null) continue;
        resolved++;
        final releases = await catalog.recentArtistAlbums(
          deezerId,
          cancelToken: cancelToken,
          background: true,
        );
        if (releases.isEmpty) continue;
        byArtist[index] = (
          artist: artist,
          releases: releases,
          libraryAlbums: await readLibraryAlbums(),
        );
      } on Object catch (error) {
        if (cancelToken.isCancelled) return;
        failed++;
        AppLogger.debug('New releases: skipped an artist: $error');
      }
    }
  }

  await Future.wait<void>([
    for (var w = 0; w < math.min(_kNewReleasesWorkers, artists.length); w++)
      worker(),
  ]);
  if (cancelToken.isCancelled) return const <HomeNewRelease>[];
  final releases = selectNewReleases(
    byArtist.nonNulls.toList(growable: false),
    today: ref.read(homeNewReleasesClockProvider)(),
  );
  ref.read(integrationCallRecorderProvider).span(kHomeNewReleasesSpan, {
    'artists': artists.length,
    'resolved': resolved,
    'failed': failed,
    'releases': releases.length,
    'inLibrary': releases.where((r) => r.libraryAlbumId != null).length,
  }, timer.elapsed);
  return releases;
});

/// Trending's remembered matches, per server account. Sign-out and a
/// library cache reset clear it; an account change drops its pending saves.
final trendingMatchStoreProvider = Provider<ArtistTopTrackMatchStore>((ref) {
  final store = ArtistTopTrackMatchStore(
    cache: ref.watch(integrationJsonCacheProvider),
    accountScope: ref.watch(integrationAccountScopeProvider) ?? 'signed-out',
    namespace: kTrendingMatchNamespace,
    keepFor: kTrendingMatchKeepFor,
  );
  ref.onDispose(store.invalidate);
  return store;
});

/// The top-song matcher on Trending's own store.
final trendingTrackResolverProvider = Provider<ArtistTopTrackResolver>((ref) {
  return ArtistTopTrackResolver(
    libraryDao: ref.watch(navisDatabaseProvider).libraryDao,
    api: ref.watch(subsonicApiProvider),
    store: ref.watch(trendingMatchStoreProvider),
    recorder: ref.watch(integrationCallRecorderProvider),
  );
});

/// Starts Trending Now again, through [HomeTrendingRefreshNotifier.refresh]:
/// `manual` for a pull to refresh or a retry, which searches more songs at
/// once, shows progress and searches unmatched songs again; otherwise as
/// Home's own refresh after a library sync.
///
/// The state is the latest request. A manual request applies only to the
/// one run it starts: [takeManual] hands it out once, so a later rebuild
/// for another reason (a switch toggled, the account) runs automatically.
class HomeTrendingRefreshNotifier extends Notifier<({int epoch, bool manual})> {
  /// The manual request already handed out. A plain field, not state: the
  /// provider consumes it while building.
  int _consumedManualEpoch = -1;

  @override
  ({int epoch, bool manual}) build() => (epoch: 0, manual: false);

  void refresh({required bool manual}) =>
      state = (epoch: state.epoch + 1, manual: manual);

  /// Whether the latest request is a manual one no run has used yet.
  bool takeManual() {
    if (!state.manual || state.epoch == _consumedManualEpoch) return false;
    _consumedManualEpoch = state.epoch;
    return true;
  }
}

final homeTrendingRefreshProvider =
    NotifierProvider<HomeTrendingRefreshNotifier, ({int epoch, bool manual})>(
      HomeTrendingRefreshNotifier.new,
    );

/// Matches Trending again after a library sync that changed the library,
/// like the weekly playlists: the library pass finds songs the sync brought,
/// and only songs due for their daily recheck are searched. A refresh
/// started meanwhile (Home's pull to refresh starts one right after its
/// sync) already sees the synced library, so it is not replaced.
final homeTrendingSyncRefreshBridgeProvider = Provider<void>((ref) {
  ref.listen<bool>(
    librarySyncControllerProvider.select(
      (state) =>
          state.status == LibrarySyncStatus.succeeded ||
          state.status == LibrarySyncStatus.partial,
    ),
    (previous, finished) {
      if (!finished || previous == true) return;
      final epochAtSync = ref.read(homeTrendingRefreshProvider).epoch;
      // Deferred past the widget build that may have delivered the sync.
      unawaited(
        Future<void>(() {
          if (!ref.mounted ||
              ref.read(homeTrendingRefreshProvider).epoch != epochAtSync) {
            return;
          }
          ref.read(trendingTrackResolverProvider).forgetSearches();
          ref.read(homeTrendingRefreshProvider.notifier).refresh(manual: false);
        }),
      );
    },
  );
});

/// Trending Now (`deezer.trending`): every song of Deezer's chart, in chart
/// order and numbered by chart position, matched the way the ListenBrainz
/// weekly playlists are.
///
/// Empty, without asking Deezer, while the switch is off or the library has
/// no artists. Otherwise, once Home is idle, it reads `/chart/0/tracks`
/// (100, cached 6 hours, a background request) and matches every song with
/// the top-song matcher on Trending's own store: remembered matches and
/// `ext-deezer-song-<id>` rows, the library pass, then `search3` on the
/// server, where a copy on the server wins over a remote one. The rows show at once, still matching,
/// then with their songs; songs found nowhere stay as unmatched rows. Two
/// songs are searched at once; a pull to refresh searches six, updates the
/// rows as it goes and searches unmatched songs again. The provider lives
/// for the session; a refresh or turning the switch off cancels its
/// searches. A failed chart request leaves Trending empty.
final homeTrendingProvider = StreamProvider<List<ResolvedArtistTopTrack>>((
  ref,
) async* {
  ref
    ..watch(homeTrendingSyncRefreshBridgeProvider)
    ..watch(homeTrendingRefreshProvider);
  final manual = ref.read(homeTrendingRefreshProvider.notifier).takeManual();
  final scope = ref.watch(integrationAccountScopeProvider);
  final allowed = ref.watch(
    integrationPolicyProvider.select(
      (policy) => policy.allows(IntegrationFeature.deezerTrending),
    ),
  );
  if (!allowed || scope == null) {
    yield const <ResolvedArtistTopTrack>[];
    return;
  }
  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);
  final catalog = ref.watch(deezerCatalogProvider);
  final resolver = ref.watch(trendingTrackResolverProvider);
  final database = ref.watch(navisDatabaseProvider);
  if (await database.libraryDao.countArtists() == 0) {
    yield const <ResolvedArtistTopTrack>[];
    return;
  }
  if (!ref.mounted) return;
  await ref.watch(homeDeezerIdleProvider.future);
  if (!ref.mounted) return;

  final timer = Stopwatch()..start();
  final chart = await catalog.chartTracks(
    cancelToken: cancelToken,
    background: true,
  );
  if (cancelToken.isCancelled) return;
  if (chart.isEmpty) {
    yield const <ResolvedArtistTopTrack>[];
    return;
  }
  final seeds = <ArtistTopTrackSeed>[
    for (var i = 0; i < chart.length; i++)
      ArtistTopTrackSeed(
        rank: i + 1,
        title: chart[i].title,
        artist: chart[i].artist.name,
        source: ArtistTopTrackSource.deezer,
        popularity: chart[i].rank,
        album: chart[i].album?.title,
        durationSeconds: chart[i].durationSeconds,
        deezerTrackId: chart[i].id,
      ),
  ];
  var rows = const <ResolvedArtistTopTrack>[];
  await for (final next in resolver.resolve(
    artistId: kTrendingMatchKey,
    seeds: seeds,
    cancelToken: cancelToken,
    searchWorkers: manual
        ? _kTrendingManualSearchWorkers
        : _kTrendingSearchWorkers,
    spanPrefix: kTrendingMatchSpanPrefix,
    researchUnmatched: manual,
    yieldPendingRows: true,
    progressEvery: manual ? _kTrendingProgressEvery : null,
  )) {
    if (cancelToken.isCancelled) return;
    rows = next;
    yield next;
  }
  if (cancelToken.isCancelled) return;
  final playable = rows.map((row) => row.resolvedSong).nonNulls;
  ref.read(integrationCallRecorderProvider).span(kHomeTrendingSpan, {
    'chart': chart.length,
    'playable': playable.length,
    'remote': playable
        .where(
          (song) => isExternalCatalogSource(
            id: song.id,
            apiIsExternal: song.isExternal,
          ),
        )
        .length,
    'manual': manual ? 1 : 0,
  }, timer.elapsed);
});
