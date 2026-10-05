import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/domain/new_releases.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Library artists whose releases Home's New releases checks.
const int kNewReleasesCandidateArtists = 30;

/// Artists checked at once; the Deezer limiter still paces the requests.
const int _kNewReleasesWorkers = 3;

/// Span name on `IntegrationCallRecorder`, for the diagnostics endpoint.
const String kHomeNewReleasesSpan = 'home.newReleases';

/// How long Home waits, once no library sync is running, before its Deezer
/// sections ask Deezer, so the first screen and the sync come first.
final homeDeezerStartupDelayProvider = Provider<Duration>(
  (_) => const Duration(seconds: 3),
);

/// Completes once Home is idle: no library sync is running and the startup
/// delay has passed. Kept for the session, so a pull to refresh or a switch
/// turned back on does not wait again.
final homeDeezerIdleProvider = FutureProvider<void>((ref) async {
  while (ref.read(listenBrainzDiscoverStartupSyncStateProvider).isRunning) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!ref.mounted) return;
  }
  final delay = ref.read(homeDeezerStartupDelayProvider);
  if (delay > Duration.zero) await Future<void>.delayed(delay);
});

/// Today, for the New releases window; overridden by tests.
final homeNewReleasesClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

/// New releases from your artists (`deezer.newReleases`): releases from the
/// last 30 days by the [kNewReleasesCandidateArtists] library artists played
/// most (liked ones first among equals), newest first.
///
/// Empty, without asking Deezer, while the switch is off or when the user
/// has no played or liked artists. Otherwise it waits for
/// [homeDeezerIdleProvider], then reads each artist's Deezer id (resolver,
/// cached 30 days) and first releases (cached 24 hours) through the
/// limiter. An artist Deezer does not know, or whose request fails, is
/// skipped; leaving Home cancels the requests.
final homeNewReleasesProvider = FutureProvider<List<HomeNewRelease>>((
  ref,
) async {
  final allowed = ref.watch(
    integrationPolicyProvider.select(
      (policy) => policy.allows(IntegrationFeature.deezerNewReleases),
    ),
  );
  if (!allowed) return const <HomeNewRelease>[];
  final dao = ref.watch(navisDatabaseProvider).libraryDao;
  final artists = await dao.getTopPlayedArtists(
    limit: kNewReleasesCandidateArtists,
  );
  if (artists.isEmpty) return const <HomeNewRelease>[];
  await ref.watch(homeDeezerIdleProvider.future);
  if (!ref.mounted) return const <HomeNewRelease>[];

  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);
  final resolver = ref.read(deezerArtistResolverProvider);
  final catalog = ref.read(deezerCatalogProvider);
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
