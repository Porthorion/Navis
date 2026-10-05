import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/domain/new_releases.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/presentation/artist_deezer_providers.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/metadata_normalization.dart';

/// Library artists whose releases Home's New releases checks.
const int kNewReleasesCandidateArtists = 30;

/// Artists checked at once; the Deezer limiter still paces the requests.
const int _kNewReleasesWorkers = 3;

/// Span name on `IntegrationCallRecorder`, for the diagnostics endpoint.
const String kHomeNewReleasesSpan = 'home.newReleases';

/// The fewest playable chart songs Trending Now needs to show.
const int kTrendingMinimumPlayable = 8;

/// Chart songs searched on the server at once.
const int _kTrendingSearchWorkers = 2;

/// The key Trending's remembered matches are stored under.
const String kTrendingMatchKey = 'deezer-chart';

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
/// limiter. An artist Deezer does not know, or whose request fails, is
/// skipped. The provider lives for the session; invalidating it (pull to
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
        );
        if (deezerId == null) continue;
        resolved++;
        final releases = await catalog.recentArtistAlbums(
          deezerId,
          cancelToken: cancelToken,
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

/// Trending Now (`deezer.trending`): the chart songs the user can play, in
/// chart order, each ranked by its chart position.
///
/// Empty, without asking Deezer, while the switch is off or the library has
/// no artists. Otherwise, once Home is idle, it reads `/chart/0/tracks`
/// (100, cached 6 hours) and matches the songs with the artist Top Songs
/// matcher under its own key: remembered matches and `ext-deezer-song-<id>`
/// rows, the local pass, then `search3`, only for songs by artists in the
/// library and by two workers. The provider lives for the session; invalidating
/// it (pull to refresh) or turning the switch off cancels its searches. The
/// chart is
/// regional and mostly other people's music, so the rest stay unmatched and
/// are dropped. Fewer than [kTrendingMinimumPlayable] playable songs, or a
/// failed chart request, leaves Trending out.
final homeTrendingProvider = FutureProvider<List<ResolvedArtistTopTrack>>((
  ref,
) async {
  final scope = ref.watch(integrationAccountScopeProvider);
  final allowed = ref.watch(
    integrationPolicyProvider.select(
      (policy) => policy.allows(IntegrationFeature.deezerTrending),
    ),
  );
  if (!allowed || scope == null) return const <ResolvedArtistTopTrack>[];
  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);
  final catalog = ref.watch(deezerCatalogProvider);
  final resolver = ref.watch(artistTopTrackResolverProvider);
  final artistIndex = ref.watch(libraryArtistNameIndexProvider);
  final database = ref.watch(navisDatabaseProvider);
  if (await database.libraryDao.countArtists() == 0) {
    return const <ResolvedArtistTopTrack>[];
  }
  if (!ref.mounted) return const [];
  await ref.watch(homeDeezerIdleProvider.future);
  if (!ref.mounted) return const <ResolvedArtistTopTrack>[];

  final timer = Stopwatch()..start();
  final chart = await catalog.chartTracks(cancelToken: cancelToken);
  if (chart.isEmpty || cancelToken.isCancelled) {
    return const <ResolvedArtistTopTrack>[];
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
  final libraryArtists = (await artistIndex.current()).lookupAll(
    seeds.map((seed) => seed.artist),
  );
  if (!ref.mounted || cancelToken.isCancelled) return const [];
  final resolved = await resolver
      .resolve(
        artistId: kTrendingMatchKey,
        seeds: seeds,
        cancelToken: cancelToken,
        searchWorkers: _kTrendingSearchWorkers,
        shouldSearch: (seed) =>
            libraryArtists.containsKey(normalizeMetadata(seed.artist)),
        spanPrefix: kTrendingMatchSpanPrefix,
      )
      .last;
  if (cancelToken.isCancelled) return const <ResolvedArtistTopTrack>[];
  final playable = resolved
      .where((track) => track.resolvedSong != null)
      .toList(growable: false);
  ref.read(integrationCallRecorderProvider).span(kHomeTrendingSpan, {
    'chart': chart.length,
    'byLibraryArtists': seeds
        .where(
          (seed) => libraryArtists.containsKey(normalizeMetadata(seed.artist)),
        )
        .length,
    'playable': playable.length,
  }, timer.elapsed);
  return playable.length < kTrendingMinimumPlayable
      ? const <ResolvedArtistTopTrack>[]
      : List<ResolvedArtistTopTrack>.unmodifiable(playable);
});
